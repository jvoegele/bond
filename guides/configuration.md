# Configuring Contracts

Contracts can be switched off at runtime or removed at compile time, per kind and
per module. This guide covers how, and the rules that govern which combinations
are meaningful.

For what contracts *cost* when they are on — measured, per call — see the
[Overhead](overhead.md) guide.


Bond reads four application-config keys at compile time. Each accepts one
of three values:

| Value     | Compiled? | Runtime behaviour                                   | Doc section? |
|-----------|-----------|-----------------------------------------------------|--------------|
| `true`    | yes       | evaluated unless disabled via `Bond.Config`         | yes          |
| `false`   | yes       | skipped unless enabled via `Bond.Config`            | yes          |
| `:purge`  | no        | n/a — there is no code to run                       | no           |

The keys are `:preconditions`, `:postconditions`, `:invariants`, and
`:checks`. Each defaults to `true`.

```elixir
# config/prod.exs — purge contracts entirely from this build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  invariants: :purge,
  checks: :purge
```

## The contract-checking chain

`:preconditions`, `:postconditions`, and `:invariants` form a chain:

```
preconditions ≤ postconditions ≤ invariants
```

A `:postconditions` failure is only diagnostically meaningful if
`:preconditions` held first — without preconditions, an "incorrect"
output might really be the caller's fault, not the callee's. Same for
`:invariants` resting on both. Bond enforces this in two ways:

- **Compile time.** If a lower kind is `:purge`d, every higher kind must
  also be `:purge`. Mixing them produces a `CompileError` at config-
  resolution time with an explanation. To skip a kind's evaluation
  without removing the code, use `false` instead of `:purge`.

- **Runtime.** If a lower kind is `false` at runtime
  (`Bond.Config.disable(:preconditions)`), the higher kinds are also
  skipped — even if they're set to `true` themselves. Bond emits a
  one-time-per-process `Logger.warning` the first time this happens for
  a given (higher, lower) pair, so the diagnostic is visible.

`:checks` is *independent* of the chain. A `check/1` is an internal
assertion about your computation, not a contract with a caller, so it
remains meaningful regardless of any other kind's settings.

```elixir
# Valid: progressively purge from the top.
config :bond, invariants: :purge

# Valid: keep everything compiled in, runtime-disable invariants by default.
config :bond, invariants: false

# Compile error: lower purged, higher present.
config :bond, preconditions: :purge   # postconditions and invariants still :true
```

## Runtime toggling

When a kind is compiled with `true` or `false`, Bond emits a runtime
guard on every contract evaluation. The guard reads the per-kind runtime
state and evaluates the contract unless that state is exactly `false`, so
contracts can be flipped on and off without recompiling. Use
[`Bond.Config`](`Bond.Config`):

```elixir
# In IEx or a remote console, against a running release:
Bond.Config.disable(:preconditions)   # dormant
Bond.Config.enable(:preconditions)    # active again
Bond.Config.all()                     # inspect the global state
```

The state is held in a single `:persistent_term` entry, lazily seeded
from application env on first use — so `config :bond, …` in both
`config.exs` and `config/runtime.exs` is honoured. A kind with no global
setting falls back to its compile-time default (including any per-module
`:overrides`).

> **`Application.put_env/3` is not live.** Setting `:bond` app env *after*
> the first contracted call has run has no effect — the runtime state is
> cached. Use `Bond.Config` to toggle, or `Bond.Config.reset/0` to re-seed
> from current application env.

`:purge` is the only value with no runtime presence — the code isn't
compiled in, so nothing can bring it back.

The runtime check is a single lock-free `:persistent_term` read per call
per contract kind. A trivial benchmark (`bench/runtime_check_overhead.exs`,
baseline subtracted) for a `@pre is_number(x)` fixture:

| Mode      | overhead / call | note                              |
|-----------|-----------------|-----------------------------------|
| `:purge`  | ~0 ns           | no code emitted                   |
| `false`   | ~15 ns          | the gate alone                    |
| `true`    | ~85 ns          | gate + assertion evaluation       |

The enabled (`true`) cost is dominated by the gate and by evaluating the
assertion expressions themselves — **not** by the function's size. The
failure `binding()` snapshot (reported in error messages) is captured
lazily and only materialised when an assertion actually fails, so the
per-call overhead does not grow with the number of parameters or
`old(...)` captures. A wide signature with `old(...)` postconditions pays
about the same as the one-argument fixture above.

For genuinely hot-path code, prefer `:purge`. Run the benchmark on your
own hardware to reproduce; absolute numbers vary by machine and Elixir
version.

## Per-module overrides

Use `:overrides` in your `:bond` config to make exceptions to the global
defaults. Each entry is `{Module | Regex, opts}`. Module-atom keys match
exactly; `Regex` keys match against the source-visible module name (no
`Elixir.` prefix).

```elixir
config :bond,
  preconditions: true,
  postconditions: true,
  overrides: [
    {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
    {~r/Workers\./, postconditions: false}
  ]
```

Precedence (most specific wins):

1. `use Bond, opts` on the using module (highest).
2. `:overrides` entry whose key is an exact module atom.
3. `:overrides` entry whose key is a regex (first match in list order wins).
4. Global `:bond` config (lowest).

A module can also opt out (or in) directly at the `use` site:

```elixir
defmodule MyApp.HotPath do
  use Bond, preconditions: :purge, postconditions: :purge
end
```
