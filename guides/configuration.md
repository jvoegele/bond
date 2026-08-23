# Configuring Contracts

Contracts can be switched off at runtime or removed at compile time, per kind and
per module. This guide covers how, and the rules that govern which combinations
are meaningful.

For what contracts *cost* when they are on — measured, per call — see the
[Overhead](overhead.md) guide.

## The three modes

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

The chain is inherited from Eiffel, where assertion monitoring is a single ordered scale
— `no`, `require`, `ensure`, `invariant`, … — in which each level implies the ones before
it, for exactly this reason: "it does not make sense to monitor postconditions unless you
also monitor preconditions, since a routine is required to ensure its postcondition only
if it was called with its precondition satisfied" (*Object-Oriented Software
Construction*, 2nd edition, §11.13).

`:checks` is *independent* of the chain, and this is a deliberate departure — Eiffel puts
`check` at the top of the same scale. A `check/1` is an internal assertion about your own
computation, not a contract with a caller, so nothing about its meaning depends on
whether a precondition was verified first. Keeping it separate lets you strip contracts
from a build while leaving internal assertions in, or the reverse.

```elixir
# Valid: progressively purge from the top.
config :bond, invariants: :purge

# Valid: keep everything compiled in, runtime-disable invariants by default.
config :bond, invariants: false

# Compile error: lower purged, higher present.
config :bond, preconditions: :purge   # postconditions and invariants still true
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
per contract kind — the whole reason `false` is affordable enough to leave
compiled into a production build. The [Overhead](overhead.md) guide has the
measured per-call figures for each kind in each mode.

The enabled (`true`) cost is dominated by the gate and by evaluating the
assertion expressions themselves — **not** by the function's size. The
failure `binding()` snapshot (reported in error messages) is captured
lazily and only materialised when an assertion actually fails, so the
per-call overhead does not grow with the number of parameters or
`old(...)` captures. A wide signature with `old(...)` postconditions pays
about the same as a one-argument one.

For genuinely hot-path code, prefer `:purge`.

### Purging can orphan an import or a helper

Purging removes the assertion, and anything that existed *only* to serve it
becomes unused. Two shapes, both of which a release built with
`--warnings-as-errors` will fail on:

```elixir
defmodule Track do
  use Bond
  import Bond.Predicates          # warning: unused import Bond.Predicates

  @pre ok: is_integer(n) ~> (n > 0)
  def f(n), do: n
end
```

```elixir
@pre ok: positive?(n)
def f(n), do: n

defp positive?(x), do: x > 0     # warning: function positive?/1 is unused
```

This is not fixable from inside Bond: purging happens in the `@`-annotation
macro, which has no way to retract an `import` or a `defp` you wrote. What makes
it bite is *where* it appears — the purging build is usually production, which
is the last one compiled and the one most likely to be gated on warnings.

Three ways out, in the order they are usually right:

  * **Use `false` instead of `:purge`.** The assertions stay compiled in and
    the import stays used. This is the common case: `false` costs one
    `:persistent_term` read per call per kind, which is affordable in almost
    any build (see [Overhead](overhead.md)).
  * **Drop the import.** Write the implication as `not p or q` — `~>` is the
    only thing most modules import `Bond.Predicates` for.
  * **Give the helper a second caller**, or inline it into the assertion.

If you do purge, compile that configuration in CI rather than discovering it at
release time. Bond's own CI does this for the downstream consumer project with a
`MIX_ENV=purged mix compile --warnings-as-errors` step.

## Choosing what runs in production

Dev and test almost always want everything on. Production is a real decision, and the
three modes combine into three postures worth knowing:

**Everything purged.** No contract code in the build at all.

```elixir
# config/prod.exs
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  invariants: :purge,
  checks: :purge
```

**Preconditions only.** The chain requires that a purged kind has every kind *above* it
purged — so the lowest kind is the one you can keep:

```elixir
# config/prod.exs
config :bond,
  preconditions: true,
  postconditions: :purge,
  invariants: :purge,
  checks: :purge
```

Preconditions have the best cost-to-value ratio of the three. They are the cheapest to
evaluate — roughly a third of an invariant, which fires twice per call and shape-tests the
return value (see [Overhead](overhead.md)) — and they are the only kind that catches a
**caller's** bug. That is exactly the failure you cannot reconstruct from the callee's
logs afterwards: a precondition violation names the caller and hands you the binding it
called with. This is close to Eiffel's own default posture, where monitoring is set to
`require` across the system and raised only for selected classes.

**Compiled in, switched off.** Use `false` instead of `:purge` to keep the checks in the
build but inert, so they can be enabled from a remote console mid-incident:

```elixir
# config/prod.exs
config :bond, preconditions: false, postconditions: false, invariants: false
```

```elixir
# then, in a remote console on the running release
Bond.Config.enable(:preconditions)
```

You pay the runtime gate on every call (a single `:persistent_term` read) and nothing for
the assertions until you switch them on. Mixing postures is fine, and
[per-module overrides](#per-module-overrides) are how you do it — purge the hot paths,
keep preconditions everywhere else.

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
    {MyApp.HotPath, preconditions: :purge, postconditions: :purge, invariants: :purge},
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
  use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge
end
```

The same top-down rule applies here as in global config: a `:purge`d kind
requires every kind above it to be `:purge`d too, whether the setting arrives
from `config :bond`, an `:overrides` entry, or `use Bond`.
