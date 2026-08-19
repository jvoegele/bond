# Overhead

Bond ships with two benchmarks under `bench/` so you can measure overhead
on your own hardware. This guide publishes reference numbers from one
documented environment to give you a starting point — but the methodology
is more important than the absolute numbers, since the latter depend on
CPU, OS, Elixir version, and what else the machine is doing.

## How to read these numbers

The short version, for the impatient:

  * **`:purge`** removes contracts at compile time. **Zero runtime
    overhead.** A `:purge`d contract isn't in the BEAM at all.
  * **`true` (the default)** evaluates contracts at runtime. The
    per-call cost is tens to hundreds of nanoseconds depending on what
    you're checking. For typical request-handling code (millisecond-
    range latencies), contracts are noise. For tight inner loops at
    nanosecond scales, the cost shows up — measure for your case.
  * **`false`** keeps the wrapper compiled in but consults runtime
    config to decide whether to evaluate. A **small fraction** of the
    cost of `true` — the gate is one `:persistent_term` read and the
    predicate never runs, so it lands between roughly 7% and 30% of the
    enabled cost depending on the kind. Useful for "compile contracts in but
    leave them off by default in production, flip on for incident
    debugging."

Compile-time overhead is roughly **35 ms per module** that uses Bond
with a few contracts. For a 200-module app, that's about 7 seconds added
to a clean `mix compile`. Incremental compiles only re-run on changed
files, so the cost is amortized after the first build.

## Reference environment

All numbers below are from a single host, measured 2026-08-19:

  * **CPU:** Apple M3 Max (16 cores)
  * **RAM:** 64 GB
  * **OS:** macOS 26.5.2
  * **Erlang/OTP:** 29 (erts-17.0.1, JIT)
  * **Elixir:** 1.20.0
  * **Bond:** 1.14.0

Don't take these as a promise across hardware. A Linux x86_64 server,
a Raspberry Pi, or a CI runner will produce different numbers. The
relative cost structure (the *shape* of the table) is more stable than
the absolute values.

## Compile-time overhead

**Benchmark file:** `bench/compile_overhead.exs`.

**Methodology:** Generate 200 module source strings on the fly, half
with `use Bond` + 6 contracts (3 functions × `@pre`/`@post`), half
plain modules with the same 3 functions. Compile each batch via
`Code.compile_string/1` in the parent VM. 2 warmup runs (discarded), 5
measured repeats per kind, median reported. Each repeat uses a fresh
module-name namespace so prior compilations don't add redefinition
purge cost to the measurement.

The in-process approach measures pure compile cost (macro expansion +
Bond's per-module compile-time processing + BEAM compile) without the 1-2 seconds of VM
startup overhead a subprocess `mix compile` would add. The disk-write
cost of an actual `mix compile` adds a roughly constant amount across
both kinds, so it cancels out of the differential reported here.

### Results — 200 modules, median of 5 runs

| Kind | Total | Per module |
| --- | ---: | ---: |
| Baseline (no Bond) | 520 ms | 2.6 ms/module |
| With Bond (every module + 6 contracts) | 7431 ms | 37.2 ms/module |
| **Overhead added by Bond** | **6911 ms** | **35 ms/module** |

Ratio: ~14× baseline — but treat the ratio as the soft number here. The
**per-module overhead** reproduces to within a few percent across runs
(6911 ms and 6945 ms on two consecutive runs); the ratio swings between
about 14× and 17× on the same machine, because the 200-module baseline
is small enough (~0.5 s) that ordinary scheduling noise moves the
denominator. Compare per-module deltas, not ratios.

For a typical application:

  * **100 modules using Bond:** ~3.5 s of additional `mix compile` time
    on a clean build.
  * **500 modules:** ~18 s.
  * **1000+ modules:** ~35 s — still amortized away by incremental
    compilation after the first build, but long enough to be felt in a
    "watch for changes and rebuild" loop, and worth measuring against
    your own codebase with `bench/compile_overhead.exs` before deciding
    whether `:purge`ing in dev is worth it.

That figure is roughly three times what it was before 1.14.0, and the
increase is deliberate. Bond wraps each emitted assertion in a `try/rescue`
so that an assertion which *raises* — rather than returning true or false —
is reported as a `Bond.AssertionEvaluationError` naming the contract, instead
of a bare `FunctionClauseError` from inside your predicate with nothing to
connect it to Bond. See
[Assertions must be total](writing-sound-assertions.md#assertions-must-be-total-not-merely-side-effect-free).

The cost is the `try` block's presence in the generated code, about 3 ms per
assertion per module; it is paid on clean builds and amortised by incremental
compilation. Measured alternatives that avoid it — emitting no `try`, or
moving it into Bond's runtime behind a closure — both cost two to three times
more *per call*, so the trade also happens to favour this shape at runtime.
The measurements are in
[#96](https://github.com/jvoegele/bond/issues/96), and CI now guards the
figure against drifting further.

Bond starts a `:gen_statem` per compiling module (stopped in
`__after_compile__`), so the per-module overhead is roughly constant
regardless of how many contracts you put on each function. Adding more
contracts per function increases the per-module number; cutting back to
one `@pre` per function would shave a few ms off.

## Runtime overhead

**Benchmark file:** `bench/runtime_check_overhead.exs`.

**Methodology:** Each measurement is a tight `for _ <- 1..N, do: fun.()`
loop after a 1000-iteration warmup. 1,000,000 iterations per repeat; 7
repeats per cell; median reported (more robust to GC pauses and
scheduler pre-emption than mean). Min and max from the 7 samples are
also reported so the spread is visible.

The table below is one representative run. Whole-benchmark invocations
also vary: three consecutive runs on the reference host agreed within a
few ns on every cell except the `:purge` rows and the struct baseline,
which sit close enough to the noise floor (~10 ns) that a single run can
misreport them by 5–10 ns. If a `:purge` row looks *faster* than
baseline on your machine, that is measurement noise, not a speedup —
`:purge` emits no wrapper, so baseline is exactly what it should cost.

Each contract kind is measured in three modes:

  * **`:purge`** — contract removed at compile time. No wrapper.
  * **`true`** — contract evaluated at runtime (default config).
  * **`false`** — wrapper compiled in but defaults to skip; runtime
    config can flip it back on without recompiling.

The runtime check for `false` reads a single `:persistent_term` entry on
every call (seeded from application env on first use; see `Bond.Config`).
The runtime check for `true` reads the same entry on every call, resolves
to the default `true` value, and then evaluates the contract expression.

### Baseline (no Bond)

| Function shape | ns/call |
| --- | ---: |
| plain function `def f(x), do: x` | 11.3 |
| struct function `def f(%__MODULE__{} = s), do: s` | 13.9 |

### `@pre` only — `@pre is_number(x)` on a plain function

Only the precondition wrapper is emitted; all other kinds `:purge`d.

| Mode | ns/call | Δ over baseline |
| --- | ---: | ---: |
| `:purge` | 10.7 | ~0 (essentially baseline) |
| `false` (runtime-disabled) | 24.7 | +13 ns |
| `true` (enabled) | 89.4 | +78 ns |

### `@post` over `@pre` (marginal cost of adding `@post`)

The chain `preconditions ≤ postconditions` means measuring `@post` in
isolation isn't possible. This row reports cost when `@pre` is already
enabled, with `@post` varying. Subtract the `@pre` `true` row above
(89.4 ns) to get the marginal cost of `@post`.

| Mode | ns/call | Marginal Δ over `@pre` true |
| --- | ---: | ---: |
| `:purge` | 89.4 | ~0 ns |
| `false` (runtime-disabled) | 96.3 | +7 ns |
| `true` (enabled) | 173.9 | +85 ns |

### `@invariant` only — `@invariant subject.value > 0` on a struct method

The fixture declares no `@pre`/`@post`, so although the chain requires the
lower kinds to be compiled in, there is nothing for them to check and the
numbers isolate the invariant.

| Mode | ns/call | Δ over baseline (struct) |
| --- | ---: | ---: |
| `:purge` | 14.0 | ~0 (essentially baseline) |
| `false` (runtime-disabled) | 34.9 | +21 ns |
| `true` (enabled) | 229.4 | +216 ns |

`@invariant` is more expensive than `@pre` or `@post` because it fires
twice (on entry, on exit) and does a struct-shape check on the return
value to decide whether to fire the post-check.

### `check/1` only — `check is_number(x)` inside the function body

| Mode | ns/call | Δ over baseline |
| --- | ---: | ---: |
| `:purge` | 11.0 | ~0 (essentially baseline) |
| `false` (runtime-disabled) | 20.0 | +9 ns |
| `true` (enabled) | 272.3 | +261 ns |

An enabled `check/1` is the most expensive single assertion in the table —
noticeably dearer than an enabled `@pre` evaluating the same predicate. A
`@pre` is hoisted into a lifted `defp` that the wrapper calls once per call
with an already-assembled argument list; a `check/1` sits in the middle of
your function body, where the assertion has to be evaluated against the
full local scope at that point. Disabled (`false`), it collapses to the
cheapest `false` row in the table: the gate reads one `:persistent_term`
entry and skips everything.

### Wide signature — `@pre` + `@post` with `old/1` on an arity-6 function

The one row that exercises the generated code at realistic width.

| Mode | ns/call |
| --- | ---: |
| plain `f/6`, no Bond | 12.3 |
| `:purge` | 9.6 |
| `true` (enabled) | 181.4 |

An enabled `@pre` + `@post` with an `old/1` capture over six parameters
costs about the same as the same pair over one parameter (173.9 ns above).
The failure `binding()` snapshot is captured lazily and only materialised
when an assertion actually fails, so per-call cost tracks the number of
assertions, not the width of the signature.

### What this means

Some rules of thumb that fall out of the numbers:

  * **For "normal" code at millisecond-or-greater latencies, contract
    overhead is invisible.** A typical HTTP request taking 5 ms
    (5,000,000 ns) wouldn't notice a 100 ns contract check on the
    request handler.
  * **For tight loops processing >10M items/sec**, contract overhead
    *will* show up. Either `:purge` contracts on the hot path or
    accept a 5–10% slowdown.
  * **`false` is genuinely useful for production toggling.** It's
    cheaper than `true` (because the predicate doesn't evaluate) but
    still keeps the wrapper around so you can flip the runtime config
    when you need to debug a specific incident.
  * **`:purge` is the right default for hot-path modules in
    production.** Per-module overrides give you per-module control —
    see [Per-module overrides](configuration.md#per-module-overrides).

## Re-running on your hardware

Numbers above are from one machine. To re-run on yours:

```sh
# From the Bond repo root
mix run bench/runtime_check_overhead.exs    # runtime overhead
mix run bench/compile_overhead.exs          # compile-time overhead
```

Each benchmark takes about a minute. Both print methodology details at
the top of their output. If you want to change the parameters —
iteration counts, repeat counts, module counts — they're constants at
the top of each `.exs` file.

If you observe numbers that are wildly different from the reference
numbers above on similar hardware, that's worth an issue — it usually
indicates either a Bond regression or an interaction with something
specific to your environment (background processes, BEAM flags,
unusual GC settings).
