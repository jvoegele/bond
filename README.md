# Bond

<!-- README START -->

Design By Contract for Elixir.

Bond lets you attach preconditions and postconditions to your functions and
verify them at runtime. A contract is a plain Elixir boolean expression with
optional labels:

```elixir
defmodule Account do
  use Bond

  @pre positive_amount: amount > 0
  @post non_negative_balance: result >= 0
  def withdraw(balance, amount), do: balance - amount
end
```

When a contract fails, Bond raises a `Bond.PreconditionError` or
`Bond.PostconditionError` with the failing assertion's label, expression,
location, and the local binding — telling you exactly what went wrong and
where.

Bond is an implementation of the
[Design By Contract](https://en.wikipedia.org/wiki/Design_by_contract)
methodology (also called _programming by contract_), introduced by Bertrand
Meyer with the Eiffel language. See the
[About](guides/about.md) guide for background.

## Usage

`use Bond` in any module to enable the `@pre`, `@post`, `check/1`, and
`check/2` annotations. Contracts may use any Elixir expression that returns
a boolean (or a truthy value).

```elixir
defmodule Math do
  use Bond

  @pre numeric_x: is_number(x), non_negative_x: x >= 0
  @post float_result: is_float(result),
        non_negative_result: result >= 0.0,
        "sqrt of 0 is 0": (x == 0) ~> (result === 0.0),
        "sqrt of 1 is 1": (x == 1) ~> (result === 1.0),
        "x > 1 implies result smaller than x": (x > 1) ~> (result < x)
  def sqrt(x), do: :math.sqrt(x)
end
```

`@pre` and `@post` accept one or more labelled assertions. Preconditions
have access to the function's parameters; postconditions also have access
to the `result` variable (bound to the function's return value) and
`old(...)` expressions that snapshot a value before the function runs (see
[`old` expressions](#module-old-expressions) below).

Bond also provides a `check/1,2` macro for placing assertions at arbitrary
points inside a function body — useful for sanity checks during development.
`check` honours the `:bond, :checks` config (see
[Conditional compilation](#module-conditional-compilation)) and is safe to
disable in production builds.

> #### When to use `check` {: .warning}
>
> Don't use `check` for input validation, validating data from external
> systems, or anything else that protects the integrity of your code. If
> the check were removed (or compiled out via config), the system must still
> behave correctly. Use ordinary control flow for that.

> #### `use Bond` {: .info}
>
> `use Bond` overrides `Kernel.@/1` so that `@pre`, `@post`, and `@doc`
> annotations can be intercepted and recorded, and installs `@on_definition`,
> `@before_compile`, and `@after_compile` compiler hooks that wrap functions
> with contracts via `defoverridable` at the end of module compilation. Your
> `def`s and `defp`s are otherwise left alone.
>
> `use Bond` also imports the `Bond` module so the `check/1` and `check/2`
> macros are available, and imports `Bond.Predicates` so the predicate
> functions and operators defined there (such as `~>` and `|||`) can be used
> in assertions. `Bond.Predicates` can be explicitly imported elsewhere if you
> want the operators outside of contract expressions.

## Assertion syntax

An assertion is a boolean (or truthy) Elixir expression, optionally paired
with a label. Labels are atoms or strings; they appear in error messages
and generated documentation.

The recommended form is the **keyword list**, even for a single assertion:

```elixir
@pre positive_x: x > 0
@post non_decreasing: result >= old(result)
@pre numeric_x: is_number(x), non_negative_x: x >= 0
```

For a bare assertion where a label adds no information, the **bare form** is
also fine:

```elixir
@pre is_number(x)
@post is_float(result)
```

For symmetry with ExUnit's `assert(value, message)` and `assert message, value`
patterns, the `check/2` macro also accepts a label before or after the
expression:

```elixir
check is_number(x)
check x_is_number: is_number(x)
check "x is a number", is_number(x)
check is_number(x), "x is a number"
```

Bond also provides the `Bond.Predicates` module with operators that are often
useful in assertions — notably `~>` (logical implication) and `<~` (pattern
match). `Bond.Predicates` is automatically imported into assertion
expressions, so you can use these operators directly:

```elixir
@post (x == 0) ~> (result == 0.0)
@post {:ok, _} <~ result
```

See `Bond.Predicates` for the full list.

## `old` expressions

`old` expressions allow postconditions to access the value of any arbitrary
expression _prior to_ execution of the function body. Postconditions are
"pre-compiled" in such a way that any `old` expressions that appear in
assertions are resolved to the value that they had at the start of function
execution.

While this facility is not particularly relevant for purely functional code,
it can be useful for stateful components of an application.

For example, imagine a simple, stateful `Counter` module that uses an `Agent`
to store the current count (some Agent code omitted for brevity):

```elixir
defmodule Counter do
  use Bond

  def get_count(agent) do
    Agent.get(agent, & &1)
  end

  @post count_incremented_by_1: get_count(agent) == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
end
```

Notice how the `old` expression captures the value of `get_count/1` prior to
execution of the function, and this value is used to verify that the value of
`get_count/1` has been updated as expected.

Note, however, that there is a potential race condition in the above code.
Since Agents are inherently concurrent, it is possible that another call to
`increment_count/1` is interleaved between execution of the function body and
the call to `get_count/1` that appears in the postcondition. In this scenario
the postcondition would fail because the new value of `get_count/1` would be
at least 2 greater than the old value captured in the postcondition, rather
than exactly 1 greater as specified in the `count_incremented_by_1` assertion.

As a first attempt to alleviate this race condition we can update the
`increment_count/1` function so that it returns the updated count as its result
and use that result in the postcondition directly:

```elixir
  @post returns_updated_count: result == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.get_and_update(agent, fn count ->
      new_count = count + 1
      {new_count, new_count}
    end)
  end
```

In this version we utilize `Agent.get_and_update/3` to update the counter and
return the updated counter value in one operation. The new counter value is the
`result` of the function which can be used in postconditions. The
`returns_updated_count` assertion compares this `result` to the `old` value of
`get_count/1` to ensure that it was incremented by exactly 1.

However, as you may have noticed, it is still possible for another call to
`increment_count/1` to be interleaved between the call to `get_count/1` in the
`old` expression of the postcondition and the call to `Agent.get_and_update/3`
in the function body. Alas, there is no way to "lock" an Agent over multiple
operations to ensure that there are no concurrent updates to the Agent state.
Therefore, our only choice is to soften the guarantee made by our
postcondition:

```elixir
  @post count_increased: get_count(agent) > old(get_count(agent))
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
```

The `count_increased` assertion in the postcondition now guarantees only that
the new value of `get_count/1` is strictly greater than the old value. This
assertion always holds true regardless of the number of concurrent state
updates to the counter.

Although this assertion is not as strong as the `count_incremented_by_1`
assertion in the original version, it is the strongest we can provide given
the possibility of concurrent state updates.

Future versions of Bond may provide stronger support for stateful contracts
in the form of _invariants_ for structs and/or stateful processes, although
this is still a subject of research.

## Documenting contracts

Contracts are part of a module's public interface, in the same way that
function signatures and typespecs are. Bond treats them that way: every
function with a contract gets a `#### Preconditions` and/or
`#### Postconditions` section appended to its `@doc`, formatted as the
original assertion source. The sections appear in `ex_doc` output and in
editors that show function docs on hover (VS Code, Vim's `K`, etc.).

Auto-generated contract sections appear whether or not you wrote a `@doc`
yourself — Bond synthesises one when needed.

> #### Conditional compilation and docs {: .info}
>
> When a function has **all** of its contracts `:purge`d (see
> [Conditional compilation](#module-conditional-compilation)), the function
> runs with zero contract overhead and its auto-generated contract sections
> are also suppressed. If you want the contract documentation visible in
> production builds, leave at least one of `:preconditions` or
> `:postconditions` set to `true` or `false` (both emit the override; only
> `:purge` removes it).

## Conditional compilation

Bond reads three application-config keys at compile time. Each accepts one
of three values:

| Value     | Compiled? | Runtime behaviour                                   | Doc section? |
|-----------|-----------|-----------------------------------------------------|--------------|
| `true`    | yes       | evaluated unless `Application.put_env/3` flips it   | yes          |
| `false`   | yes       | skipped unless `Application.put_env/3` flips it     | yes          |
| `:purge`  | no        | n/a — there is no code to run                       | no           |

The keys are `:preconditions`, `:postconditions`, and `:checks`. Each
defaults to `true`.

```elixir
# config/prod.exs — purge contracts entirely from this build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  checks: :purge
```

### Runtime toggling

When a kind is compiled with `true` or `false`, Bond emits a runtime guard
on every contract evaluation that reads
`Application.get_env(:bond, <kind>, <compile_time_value>)`. The guard
evaluates the contract unless the runtime value is exactly `false`. This
means contracts can be flipped on and off without recompiling:

```elixir
# In IEx or a remote console, against a running release:
Application.put_env(:bond, :preconditions, false)  # dormant
Application.put_env(:bond, :preconditions, true)   # active again
```

`:purge` is the only value with no runtime presence — the code isn't
compiled in, so `Application.put_env/3` can't bring it back.

The runtime check is a single `Application.get_env/3` lookup per call per
contract kind. A trivial benchmark (a function with `@pre is_number(x)`
called in a tight loop) shows:

| Mode      | ns / call | Overhead vs `:purge` |
|-----------|-----------|---------------------|
| `:purge`  | ~48 ns    | —                   |
| `false`   | ~89 ns    | ~40 ns (the guard alone) |
| `true`    | ~155 ns   | ~107 ns (guard + assertion eval) |

For genuinely hot-path code, prefer `:purge`. The benchmark itself lives at
`bench/runtime_check_overhead.exs` if you want to reproduce it on your
hardware.

### Per-module overrides

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

### Migrating from 0.10.0

Before 0.10.x, `false` meant "not compiled in" (zero overhead). In 0.11.0
the value space changed:

| 0.10.x  | 0.11.0 equivalent | Notes |
|---------|---------------------|-------|
| `true`  | `true`              | Same default behaviour. Now also runtime-togglable. |
| `false` | `:purge`            | **Migration**: if you used `false` for zero-overhead, switch to `:purge`. |

In 0.11.0, `false` is a *runtime default* meaning "compiled but off by
default." If you used `false` simply to disable contracts at compile time,
change it to `:purge` to keep the same compiled output.

## Telemetry

Bond emits a [`:telemetry`](https://hexdocs.pm/telemetry/readme.html) event
whenever a `@pre`, `@post`, or `check` assertion is violated. The event
fires once per failure, immediately before the corresponding
`Bond.PreconditionError` / `Bond.PostconditionError` / `Bond.CheckError`
is raised.

**Event:** `[:bond, :assertion, :failure]`

**Measurements:**

- `:system_time` — `System.system_time/0` at the failure
- `:monotonic_time` — `System.monotonic_time/0` at the failure

**Metadata:**

- `:kind` — `:precondition | :postcondition | :check`
- `:module` — module the assertion is attached to
- `:function` — `{name, arity}` of the function containing the assertion
- `:label` — the keyword label, or `nil` if unlabelled
- `:expression` — source text of the assertion
- `:assertion_id` — stable per-assertion identifier; the same value
  appears every time the same assertion fails, so it's safe to use as
  an aggregation key
- `:file`, `:line` — source location of the assertion
- `:binding` — sorted snapshot of `binding()` at the failure site

Attach a handler at application start:

```elixir
:telemetry.attach(
  "bond-failure-logger",
  [:bond, :assertion, :failure],
  &MyApp.Telemetry.log_bond_failure/4,
  nil
)
```

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def log_bond_failure(_event, _measurements, metadata, _config) do
    Logger.warning(
      "bond #{metadata.kind} violated in " <>
        "#{inspect(metadata.module)}.#{elem(metadata.function, 0)}/" <>
        "#{elem(metadata.function, 1)}: #{metadata.expression}"
    )
  end
end
```

Only failure events are emitted in 0.12.0. Pass events would be far too
chatty for production use; if there's demand for them they can be added
later behind an opt-in.

<!-- README END -->

## Installation

`bond` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 0.12.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/bond/Bond.html) and be found at
<https://hexdocs.pm/bond/Bond.html>.
