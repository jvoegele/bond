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

`use Bond` in any module to enable the `@pre`, `@post`, and `@invariant`
annotations plus the `check/1` macro. Contracts may use any Elixir
expression that returns a boolean (or a truthy value).

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

> #### `use Bond` {: .info}
>
> `use Bond` overrides `Kernel.@/1` so that `@pre`, `@post`, `@invariant`,
> and `@doc` annotations can be intercepted and recorded, and installs
> `@on_definition`, `@before_compile`, and `@after_compile` compiler hooks
> that wrap functions with contracts via `defoverridable` at the end of
> module compilation. Your `def`s and `defp`s are otherwise left alone.
>
> `use Bond` also imports the `Bond` module so the `check/1` macro is
> available, and imports `Bond.Predicates` so the predicate functions and
> operators defined there (such as `~>` and `|||`) can be used in
> assertions. `Bond.Predicates` can be explicitly imported elsewhere if
> you want the operators outside of contract expressions.

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

For a bare assertion where a label adds no information, the **bare form**
is also fine:

```elixir
@pre is_number(x)
@post is_float(result)
```

The assertion expression can be any call or operator returning a
truthy/falsy value — including remote function calls from the standard
library or your own modules:

```elixir
@pre String.starts_with?(path, "/api/")
@pre Map.has_key?(opts, :user_id)
@post Enum.all?(result, &is_integer/1)
```

Bare literals (`@pre 42`), bare variables (`@pre x`), and other non-call
expressions aren't valid assertion forms — Bond raises a `CompileError`
with the source location and a suggested form when it sees one.

The same two forms work for `@invariant` declarations and inside function
bodies via the `check/1` macro:

```elixir
@invariant subject.capacity >= 0
@invariant non_negative_capacity: subject.capacity >= 0,
           size_within_capacity: length(subject.items) <= subject.capacity

check is_number(x)
check x_is_number: is_number(x)
```

Bond also provides the `Bond.Predicates` module with operators that are
often useful in assertions — notably `~>` (logical implication) and `<~`
(pattern match). `Bond.Predicates` is automatically imported into
assertion expressions, so you can use these operators directly:

```elixir
@post (x == 0) ~> (result == 0.0)
@post {:ok, _} <~ result
```

> #### Operator precedence trap {: .warning}
>
> `~>` and `<~` share precedence and left-associate. Nesting them
> (`A ~> pattern <~ B`) parses as `(A ~> pattern) <~ B` and fails to
> compile. Parenthesize the inner operator:
> `(x > 0) ~> ({:ok, _} <~ result)`. See `Bond.Predicates` for details.

See `Bond.Predicates` for the full list of predicates and operators.

## `@invariant` for struct modules

`@invariant` declarations specify properties that hold for every value of
a struct, checked automatically on the way *into* and *out of* every
public function in the struct's defining module.

Where `@pre`/`@post` constrain a single function call, `@invariant`
constrains the struct itself — every instance produced by the module's
public API satisfies the invariant, every instance entering its public
API is expected to.

```elixir
defmodule BoundedStack do
  use Bond

  defstruct [:items, :capacity]

  @invariant non_negative_capacity: subject.capacity >= 0,
             size_within_capacity: length(subject.items) <= subject.capacity

  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  def push(%__MODULE__{} = stack, item) do
    %{stack | items: [item | stack.items]}
  end
end
```

### The `subject` binding

Inside an `@invariant` expression, **`subject` refers to the struct
instance being checked**. Bond rebinds `subject` at every check site to
whichever struct parameter the function head exposes — you write the
invariant once against `subject` and Bond handles the rest, regardless of
what each function names its struct parameter.

### When invariants fire

Invariants check at the boundaries of public functions in the struct's
module — the places a struct value crosses between "internal" (possibly
transient) and "external" (must be valid). Bond auto-detects the struct
parameter in any of these head shapes:

| Function head shape | Detected? | Pre-check on entry |
|---|---|---|
| `def foo(%__MODULE__{} = name, ...)` | yes | yes, on the captured struct |
| `def foo(x, ...) when is_struct(x, __MODULE__)` | yes | yes, on `x` |
| `def foo(%__MODULE__{field: ...}, ...)` (destructure-only) | yes | yes, on the captured struct |
| `def foo(x, ...)` (no pattern, no guard) | no | skipped silently |
| `defp ...` (any shape) | no | skipped — private functions exempt by Eiffel convention |

The post-check on exit matches both `%__MODULE__{}` and `{:ok,
%__MODULE__{}}` return shapes. Other shapes (`{:error, _}`, bare
integers, etc.) fall through with no check. If your function returns the
struct under a different wrapper, add an explicit `@post`.

Multiple struct parameters in the same head (e.g. `def
merge(%__MODULE__{} = a, %__MODULE__{} = b)`) are all checked in
left-to-right order; `subject` rebinds to each in turn.

### Violation behaviour

A violated invariant raises `Bond.InvariantError` with the same metadata
shape as `Bond.PreconditionError` / `Bond.PostconditionError`, and fires
the same telemetry event (`[:bond, :assertion, :failure]` with
`:kind => :invariant`). Test with
`Bond.Test.assert_invariant_violation/2`.

### Generated documentation

Modules that declare `@invariant`s get an auto-generated `## Invariants`
section appended to their `@moduledoc`. The section names the struct,
explains the `subject` binding, lists each invariant in the same
`label: expression` format as per-function contract docs, and notes
when the invariants fire. Users who haven't written a `@moduledoc`
themselves get one synthesised; users who wrote `@moduledoc false`
have their decision respected.

When `:invariants` is `:purge`d (compile-time disable), the
auto-generated section is suppressed — matching the per-function
contract-doc suppression rule.

### What's not supported

Invariants are scoped to the **struct's own defining module**. External
modules that operate on the struct can't declare invariants for it —
this matches Eiffel's class-locality and keeps cross-module ownership
clean.

Process-level invariants (for `GenServer`/`Agent` state) aren't a
separate feature. The recommended pattern is to keep the process state
in a struct and declare invariants on that struct's module. See the
[Contracts in a Concurrent World](contracts-and-concurrency.html) guide.

## Inline `check/1` assertions

Bond's `check/1` macro places assertions at arbitrary points inside a
function body — useful for sanity checks during development. It honours
the `:bond, :checks` config (see [Conditional
compilation](#module-conditional-compilation)) and is safe to disable in
production builds.

```elixir
def total(items) do
  raw = Enum.sum(items)

  check raw >= 0
  check total_is_integer: is_integer(raw)

  raw
end
```

On success `check` returns the assertion's value (or list of values for
the keyword-list form). On failure it raises `Bond.CheckError`.

> #### When to use `check` {: .warning}
>
> Don't use `check` for input validation, validating data from external
> systems, or anything else that protects the integrity of your code. If
> the check were removed (or compiled out via config), the system must
> still behave correctly. Use ordinary control flow for that.

## `old` expressions

`old` expressions in postconditions snapshot a value before the function
body runs, so the postcondition can compare the after-state to the
before-state.

```elixir
defmodule Counter do
  use Bond

  def get_count(agent), do: Agent.get(agent, & &1)

  @post incremented: get_count(agent) == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
end
```

Bond resolves every `old(...)` expression at the start of function
execution and threads the captured value into the postcondition. `old`
is only available inside `@post`.

The naive form above has a race condition when used against stateful
concurrent components — another `increment_count/1` can interleave
between the `old` snapshot and the postcondition evaluation. See the
[Contracts in a Concurrent World](contracts-and-concurrency.html) guide
for the pattern that handles this. For struct-based state machines,
`@invariant` is usually a better fit than `old` — it constrains every
operation's input and output struct rather than a single delta.

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
> [Conditional compilation](#module-conditional-compilation)), the
> function runs with zero contract overhead and its auto-generated
> contract sections are also suppressed. If you want the contract
> documentation visible in production builds, leave at least one of
> `:preconditions` or `:postconditions` set to `true` or `false` (both
> emit the override; only `:purge` removes it).

## Conditional compilation

Bond reads four application-config keys at compile time. Each accepts one
of three values:

| Value     | Compiled? | Runtime behaviour                                   | Doc section? |
|-----------|-----------|-----------------------------------------------------|--------------|
| `true`    | yes       | evaluated unless `Application.put_env/3` flips it   | yes          |
| `false`   | yes       | skipped unless `Application.put_env/3` flips it     | yes          |
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

### The contract-checking chain

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
  (`Application.put_env(:bond, :preconditions, false)`), the higher
  kinds are also skipped — even if they're set to `true` themselves.
  Bond emits a one-time-per-process `Logger.warning` the first time
  this happens for a given (higher, lower) pair, so the diagnostic is
  visible.

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

### Runtime toggling

When a kind is compiled with `true` or `false`, Bond emits a runtime
guard on every contract evaluation that reads
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

The runtime check is a single `Application.get_env/3` lookup per call
per contract kind. A trivial benchmark (a function with `@pre
is_number(x)` called in a tight loop) shows:

| Mode      | ns / call | Overhead vs `:purge` |
|-----------|-----------|---------------------|
| `:purge`  | ~48 ns    | —                   |
| `false`   | ~89 ns    | ~40 ns (the guard alone) |
| `true`    | ~155 ns   | ~107 ns (guard + assertion eval) |

For genuinely hot-path code, prefer `:purge`. The benchmark itself
lives at `bench/runtime_check_overhead.exs` if you want to reproduce it
on your hardware.

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

## Telemetry

Bond emits a [`:telemetry`](https://hexdocs.pm/telemetry/readme.html)
event whenever a `@pre`, `@post`, `@invariant`, or `check` assertion is
violated. The event fires once per failure, immediately before the
corresponding `Bond.PreconditionError` / `Bond.PostconditionError` /
`Bond.InvariantError` / `Bond.CheckError` is raised.

**Event:** `[:bond, :assertion, :failure]`

**Measurements:**

- `:system_time` — `System.system_time/0` at the failure
- `:monotonic_time` — `System.monotonic_time/0` at the failure

**Metadata:**

- `:kind` — `:precondition | :postcondition | :invariant | :check`
- `:module` — module the assertion is attached to
- `:function` — `{name, arity}` of the function containing the assertion
- `:label` — the keyword label, or `nil` if unlabelled
- `:expression` — source text of the assertion
- `:assertion_id` — stable per-assertion identifier; the same value
  appears every time the same assertion fails, so it's safe to use as
  an aggregation key
- `:file`, `:line` — source location of the assertion
- `:binding` — sorted snapshot of `binding()` at the failure site

For example, a violated `@pre non_negative_x: x >= 0` on
`BondTest.Math.sqrt(-1)` produces a metadata map of this shape:

```elixir
%{
  kind: :precondition,
  module: BondTest.Math,
  function: {:sqrt, 2},
  label: :non_negative_x,
  expression: "x >= 0",
  assertion_id: "9d8c…",
  file: "/path/to/math.ex",
  line: 15,
  binding: [trap_door: nil, x: -1]
}
```

`:function` is a `{name, arity}` tuple — destructure or call
`elem/2` if you only need one half. The `:assertion_id` is stable
across firings of the same assertion, so it's safe as an
aggregation key in a counter or alerting pipeline.

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

Only failure events are emitted. Pass events would be far too chatty for
production use; if there's demand for them they can be added later
behind an opt-in.

## Property-based testing

Bond contracts compose naturally with
[StreamData](https://hex.pm/packages/stream_data) property-based
testing. The usual hard parts of PBT are generating inputs and writing
an oracle that distinguishes right answers from wrong ones; Bond's
contracts already supply the oracle at every call site. PBT then just
feeds random inputs through already-instrumented code.

`Bond.PropertyTest.contract_holds/2` ships in two forms.

### Single function

```elixir
defmodule MathTest do
  use ExUnit.Case
  use Bond.PropertyTest

  contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]
end
```

Generates a property block that calls `Math.sqrt/1` with random
non-negative floats. Any precondition, postcondition, or `check`
violation fails the property; StreamData shrinks to the minimal failing
input.

### Module sequence (invariant-driven)

```elixir
defmodule BoundedStackTest do
  use ExUnit.Case
  use Bond.PropertyTest

  contract_holds BoundedStack,
    constructors: [{:new, [StreamData.integer(1..100)]}],
    transformers: [{:push, [StreamData.term()]}, {:pop, []}],
    observers:    [{:size, []}, {:peek, []}]
end
```

Generates random *sequences* of operations over a struct module. The
constructor produces an initial struct; transformers thread state
forward (they take the current struct as their first argument);
observers take the struct but don't advance state. The module's
`@invariant`s fire on every operation entry and exit, so any violation
in any operation shrinks back to the minimal failing sequence.

Form 2 supports `%Mod{}` and `{:ok, %Mod{}}` return shapes from
constructors and transformers. `{:error, _}` terminates the sequence
cleanly (an operation refusing isn't a contract violation). Other
return shapes raise an `ArgumentError` — wrap your function or test it
with Form 1.

### Setup

`stream_data` is an optional dep of `bond`. Add it to your own deps to
enable PBT:

```elixir
def deps do
  [
    {:bond, "~> 0.18.0"},
    {:stream_data, "~> 1.0", only: [:dev, :test]}
  ]
end
```

`use Bond.PropertyTest` raises a `CompileError` with an explanation if
`stream_data` isn't on the path.

<!-- README END -->

## Installation

`bond` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 0.18.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/bond/Bond.html) and be found at
<https://hexdocs.pm/bond/Bond.html>.
