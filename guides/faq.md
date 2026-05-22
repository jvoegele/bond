# Frequently Asked Questions

## Why contracts when I have ExUnit?

Tests verify behaviour for the specific scenarios you've written. Contracts
verify behaviour on **every call** in the running system. They catch
violations you didn't think to test for, especially in long-running dev or
staging environments. Tests and contracts complement each other:

- Tests describe what your code *should* do.
- Contracts describe what your code *must always be true while doing*.

For functions that are easy to test and have well-known input shapes,
tests alone are usually fine. For functions whose preconditions are
nuanced or whose results have invariants that span many call sites,
contracts catch bugs sooner with less work.

## Will contracts slow down my production code?

Not if you `:purge` them. Bond supports
[compile-time conditional compilation](Bond.html#module-conditional-compilation):

```elixir
# config/prod.exs — strip contracts entirely from this build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  checks: :purge
```

When both `:preconditions` and `:postconditions` are `:purge`d for a
function, Bond emits no override at all and the function runs with zero
per-call overhead. The compiled BEAM contains no contract evaluation code
for that function.

A typical pattern: contracts on in dev/test, `:purge`d in prod.

## Can I toggle contracts at runtime without recompiling?

Yes — that's what `true` and `false` (as distinct from `:purge`) give you.
When a kind is compiled with `true` or `false`, the override has a runtime
guard:

```elixir
# In IEx or a remote console:
Application.put_env(:bond, :preconditions, false)  # dormant
Application.put_env(:bond, :preconditions, true)   # active again
```

The runtime check is a single `Application.get_env/3` lookup per call. For
inner-loop hot paths, `:purge` is still the right choice — runtime toggle
costs a tiny lookup; `:purge` costs nothing.

## Can I disable contracts for one specific module?

Yes, two ways.

In the source:

```elixir
defmodule MyApp.HotPath do
  use Bond, preconditions: :purge, postconditions: :purge
end
```

Or in config (handy when you don't want to touch the source):

```elixir
config :bond,
  overrides: [
    {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
    {~r/Workers\./, postconditions: false}
  ]
```

Exact module atoms match precisely. `Regex` patterns match against the
source-visible module name. The `use Bond` opts override `:overrides`,
which override the global config.

## How does Bond compare to Norm?

[Norm](https://github.com/elixir-toniq/norm) validates **data shapes** — a
value matches a spec or it doesn't. Bond verifies **function behaviour** —
a contract asserts something about the relationship between inputs,
outputs, and (optionally) prior state.

They compose well. A common pattern: use Norm to describe the shape of
data that flows in and out of your boundary functions; use Bond to assert
invariants and relationships internal to the functions that process the
data.

```elixir
# Pseudocode — Norm for shape, Bond for behaviour
@pre matches_input_spec: Norm.valid?(input, input_spec())
@post matches_output_spec: Norm.valid?(result, output_spec())
@post "no items lost": length(result) == length(input)
def transform(input), do: ...
```

## How do I disable a single failing contract while debugging?

There's no per-contract toggle in the source code today. Options:

1. **Comment it out.** Simplest. Add a `TODO` so it doesn't stay
   commented forever.
2. **Disable the kind globally.** If you only have one failing
   precondition, set `config :bond, preconditions: false` in the relevant
   environment and recompile. Heavy-handed but quick.
3. **Move the assertion to `check/1` inside the body**, where you can
   wrap it in a conditional.

If this comes up often, file an issue — there are reasonable designs for
a per-contract disable flag.

## What does Bond do that typespecs don't?

Typespecs are static documentation of input and output **types**. Tools
like Dialyzer can verify them statically, but typespecs cannot express:

- Relationships between arguments (`amount <= balance`).
- Relationships between input and output (`result <= balance`).
- Conditional invariants (`(x == 0) ~> (result == 0.0)`).
- State-change properties using `old/1`.
- Arbitrary computed predicates.

Typespecs say "this argument is an integer." Contracts say "this argument
is a positive integer less than the balance, and the result is the
balance minus the argument." Use both.

## Are contracts evaluated on the recursion path?

No — Bond implements Bertrand Meyer's
[Assertion Evaluation rule](https://en.wikipedia.org/wiki/Design_by_contract):

> During the process of evaluating an assertion at run-time, routine
> calls shall be executed without any evaluation of the associated
> assertions.

If a postcondition calls another contracted function, that inner
function's preconditions and postconditions are *not* evaluated. Without
this rule, mutually recursive contracts would loop forever. With it,
contracts are safe to use even when they call into the rest of your API.

## Can I use `check/1` to assert input validity?

No — `check/1` is for **sanity checks during development**, not input
validation. A `check` can be compiled out entirely via
`config :bond, :checks, false`, and the wrapped expression is then not
evaluated at all. If your code's correctness depends on something being
checked, use ordinary control flow:

```elixir
# DON'T: relies on check for correctness
def withdraw(balance, amount) do
  check amount > 0
  balance - amount
end

# DO: explicit guard, evaluated regardless of config
def withdraw(balance, amount) when amount > 0 do
  balance - amount
end
```

## Why does my error message report `sqrt/2` when I wrote `sqrt/1`?

If the function has a default argument, like
`def sqrt(x, trap_door \\ nil)`, Elixir generates clauses for both arities
(`sqrt/1` and `sqrt/2`). Bond attaches the contract to the higher-arity
clause, so error messages report `sqrt/2` even when the caller writes
`Math.sqrt(-1)` (which Elixir dispatches via the auto-generated `sqrt/1`
forwarder).

This is expected. If you want the error to mention `sqrt/1`, split the
default-arg form into explicit clauses.

## When does Bond check invariants?

`@invariant` declarations on a struct module are checked automatically at
the boundaries of that module's public functions. Specifically:

- **On entry**, when the function head pattern-matches `%__MODULE__{} = name`
  or has an `is_struct(name, __MODULE__)` guard. Bond pre-checks the
  invariant against `name`.
- **On exit**, against the return value if it's `%__MODULE__{}` or
  `{:ok, %__MODULE__{}}`. Other return shapes fall through without a check.
- **Never for `defp`** — private functions are exempt by the Eiffel
  convention (they often hold transiently-invalid state mid-operation).

If you want invariant pre-checks but your function doesn't pattern-match the
struct as an argument, add the pattern: `def foo(%__MODULE__{} = x, ...)`.
If you destructure but don't bind the whole struct (`def foo(%__MODULE__{f: v}, ...)`),
Bond emits a compile-time warning and skips the pre-check — add `= name` to
the pattern to fix it.

Violations raise `Bond.InvariantError` and emit `[:bond, :assertion, :failure]`
telemetry with `:kind => :invariant`. See the
[Invariants](Bond.html#module-invariants) section in the moduledoc.

## How are multi-clause functions handled?

A single contract applies to **all clauses** of a multi-clause function.
Put your `@pre` and `@post` annotations before the first clause; Bond
emits one override that wraps the whole function and lets Elixir's normal
pattern matching dispatch to the appropriate clause via `super(...)`.

Bond raises a compile error if you put `@pre` or `@post` between clauses:

```elixir
# COMPILE ERROR — contracts must precede the first clause
@pre x > 0
def foo(x) when is_integer(x), do: x * 2

@pre is_float(x)       # not allowed here
def foo(x) when is_float(x), do: round(x)
```
