# Getting Started

This guide walks you through adding Bond to a project, writing your first
contract, and the most common patterns you'll encounter.

For full reference material see the `Bond` module docs.

## Installation

Add `bond` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 1.4"}
  ]
end
```

Then run `mix deps.get`.

## Your first contract

`use Bond` in any module to enable `@pre`, `@post`, `@invariant`, and
`check/1`. Add a
precondition before a function definition:

```elixir
defmodule Calculator do
  use Bond

  @pre is_number(x)
  def square(x), do: x * x
end
```

`Calculator.square(2)` returns `4` as expected. `Calculator.square("two")`
raises `Bond.PreconditionError` with a message that points at the failing
assertion:

```text
** (Bond.PreconditionError) precondition failed for call to Calculator.square/1
|   at: lib/calculator.ex:4
|   label: nil
|   assertion: is_number(x)
|   binding: [x: "two"]
```

## Adding a postcondition

Postconditions are evaluated after the function body. They have access to
the function's parameters plus a `result` variable bound to the return
value:

```elixir
defmodule Account do
  use Bond

  @pre amount > 0
  @post result >= 0
  def withdraw(balance, amount), do: balance - amount
end
```

`Account.withdraw(100, 30)` returns `70`. `Account.withdraw(20, 50)` raises
`Bond.PostconditionError` — the function returned a negative balance, which
the postcondition forbids.

## Labelled assertions

A single `@pre` or `@post` may contain multiple labelled assertions as a
keyword list. Labels appear in error messages so it's easy to identify
which assertion failed:

```elixir
defmodule Math do
  use Bond

  @pre numeric_x: is_number(x), non_negative_x: x >= 0
  @post float_result: is_float(result),
        non_negative_result: result >= 0.0
  def sqrt(x), do: :math.sqrt(x)
end
```

Labels can be atoms (when they're valid Elixir identifiers) or strings (for
phrases with spaces or punctuation):

```elixir
@post "result is integer or zero": is_integer(result) or result == 0
```

## Predicates and operators

The `Bond.Predicates` module is automatically imported inside assertion
expressions. Two operators are especially useful in contracts:

- `~>` — logical implication. `(p ~> q)` means "if `p` then `q`".
- `<~` — pattern match. `(pattern <~ expression)` is `match?(pattern, expression)`.

```elixir
@post "sqrt of 0 is 0": (x == 0) ~> (result === 0.0)
@post {:ok, _} <~ result
```

See `Bond.Predicates` for the complete list.

## Quantified assertions

When a contract needs to assert something about *every* element of a
collection — or that *some* element exists — reach for the `forall` and
`exists` macros. They use comprehension-style generator syntax:

```elixir
defmodule Stats do
  use Bond

  @pre all_positive: forall(x <- samples, x > 0)
  def geometric_mean(samples) do
    nth_root(Enum.product(samples), length(samples))
  end

  @pre has_admin: exists(u <- users, u.role == :admin)
  def authorize(users), do: # ...
end
```

You could already write these with `Enum.all?/2` and `Enum.any?/2`, but
when one fails Bond can only tell you the *whole* expression was false.
`forall`/`exists` capture **which element** broke the contract:

```
** (Bond.PreconditionError) precondition failed for call to Stats.geometric_mean/1
|   label: :all_positive
|   assertion: forall(x <- samples, x > 0)
|   counterexample: element at index 3 (-2) does not satisfy `x > 0`
|   binding: [samples: [5, 2, 8, -2]]
```

`exists` instead reports that no element satisfied the predicate:

```
|   assertion: exists(u <- users, u.role == :admin)
|   counterexample: no element of `users` satisfies `u.role == :admin` (3 elements)
```

Both forms:

- **short-circuit** — `forall` stops at the first violation, `exists` at
  the first witness;
- return ordinary booleans, so they **compose** with `and`, `or`, `not`,
  and `~>`;
- work in `@pre`, `@post` (including quantifying over `result`),
  `@invariant`, and `Bond.check/1`.

A `@post` that quantifies over the result reads naturally — for example,
asserting a function returns a sorted list:

```elixir
@post sorted: forall(i <- 0..(length(result) - 2)//1,
                     Enum.at(result, i) <= Enum.at(result, i + 1))
def sort(list), do: Enum.sort(list)
```

### Not a `for` comprehension (or a property generator)

The `pattern <- enumerable` syntax is borrowed from `for` comprehensions —
and looks like StreamData's `check all` / `gen all` — but the resemblance
is only skin-deep. Two differences worth internalising:

- The right-hand side of `<-` is a **plain `Enumerable`** (a list, range,
  map, stream…), not a StreamData generator. The closest analogues are
  `Enum.all?/2` and `Enum.any?/2`, not `for` or property testing.
- The trailing expression is the **predicate being asserted**, *not a
  filter*. In `check all x <- list, x > 0 do … end`, the `x > 0` clause
  *discards* non-matching values; in `forall(x <- list, x > 0)` it is the
  thing that must hold for every element. There is no `do` block.

So read `forall(x <- items, x > 0)` as the logical statement "for all `x`
in `items`, `x > 0`" — not "for the `x` in `items` where `x > 0`".

### Limitations

- Each quantifier takes **one generator and one predicate**; there is no
  multi-generator or filter syntax as in a `for` comprehension. Nest a
  quantifier inside another for a Cartesian assertion. (A `for`-style
  multi-generator call raises a clear compile-time error pointing you at
  nesting.)
- When several quantifiers appear in one assertion — including **nested**
  ones — the element-level `counterexample:` line reflects the outermost
  (last-evaluated) quantifier to fail. For a single, bare quantifier it is
  exact. The plain truthy/falsy verdict is always correct regardless.

### Large collections, streams, and side effects

A quantifier **enumerates the collection** — once, lazily, stopping at the
first violation (`forall`) or first witness (`exists`). Keep three things
in mind:

- **Cost is `O(n)`.** Quantifying over a large collection on a hot path
  adds a full (short-circuited) traversal to every call, just like
  `Enum.all?/2` would. This is exactly what Bond's runtime gate is for —
  disable the kind in production (`config :bond, postconditions: false`, or
  `Bond.Config` at runtime; see
  [Disabling contracts in production](#disabling-contracts-in-production))
  so the traversal never runs there.

- **Assertions must be side-effect-free — and enumerating a lazy stream is
  a side effect.** A `@post` that quantifies over a stream `result` (or a
  `@pre` over a stream argument) will *enumerate that stream* to check the
  predicate. For a pure, re-enumerable stream that merely **doubles the
  work** — the stream runs once for the contract and again for the caller.
  But for a stream backed by a **one-shot or effectful source** —
  `IO.stream/2` over stdin, an `Ecto.Repo.stream` cursor, a socket via
  `Stream.resource/3` — the contract's enumeration consumes or re-fires the
  resource, corrupting what the caller receives. **Don't quantify over an
  effectful stream.** If the producer is finite and pure and you really
  want to assert over it, materialise it explicitly —
  `forall(x <- Enum.to_list(result), …)` — so the cost and the single
  enumeration are visible at the call site.

- **Never quantify over an infinite stream.** `forall` returns only when an
  element *fails*, and `exists` only when one *succeeds* — so an
  all-passing `forall` (or a no-match `exists`) over `Stream.cycle/1`,
  `Stream.iterate/2`, etc. never terminates. Bond can't detect this
  (a finite and an infinite stream have the same type); it's on you to
  quantify only over bounded collections.

## `old` expressions in postconditions

For functions that mutate state, a postcondition often needs to compare
the *new* state to the *old* state. The `old/1` macro snapshots a value
before the function body runs:

```elixir
defmodule TurnCounter do
  use Bond

  # Per-process turn counter stored in the process dictionary. Owned by
  # the running process, so the snapshot and the post-check observe the
  # same world.
  def current_turn, do: Process.get(:turn, 0)

  @post incremented: current_turn() == old(current_turn()) + 1
  def take_turn do
    Process.put(:turn, current_turn() + 1)
    :ok
  end
end
```

`old` is only available inside `@post`. Bond resolves every `old(...)`
expression at the start of function execution and threads the captured
value into the postcondition.

For state shared across processes — an `Agent`, a `GenServer`, an ETS
table — `old(...)` reads a snapshot that another process can race
against before the post-check runs. See the
[Contracts in a Concurrent World](contracts-and-concurrency.md) guide
for the locking pattern that handles this.

## Inline checks

For sanity checks inside a function body, use `check/1`:

```elixir
def total(items) do
  raw = Enum.sum(items)

  check raw >= 0
  check total_is_integer: is_integer(raw)

  raw
end
```

> #### `check` is for development confidence, not validation {: .warning}
>
> Don't use `check` for input validation or anything else that protects the
> integrity of your code — it can be compiled out entirely (see below).

## Invariants for struct modules

When a module defines a struct, `@invariant` declarations specify
properties that hold for every value of the struct — checked
automatically on entry and exit of every public function in the
module:

```elixir
defmodule BoundedStack do
  use Bond

  defstruct [:items, :capacity]

  @invariant size_within_capacity: length(subject.items) <= subject.capacity,
             non_negative_capacity: subject.capacity >= 0

  def new(capacity), do: %__MODULE__{items: [], capacity: capacity}

  def push(%__MODULE__{} = stack, item) do
    %{stack | items: [item | stack.items]}
  end
end
```

Inside an `@invariant` expression, `subject` refers to the struct
instance being checked. Bond detects the struct parameter in each
public function's head (`%__MODULE__{} = name` pattern,
`is_struct(_, __MODULE__)` guard, or `%__MODULE__{...}` destructure)
and rebinds `subject` to it — you write the invariant once and Bond
applies it everywhere.

See the [`@invariant`](Bond.html#module-invariant-for-struct-modules)
section of the moduledoc for head-shape detection, multi-struct
heads, and per-module configuration.

## Disabling contracts in production

Bond's four application-config keys — `:preconditions`, `:postconditions`,
`:invariants`, `:checks` — each accept `true`, `false`, or `:purge`:

```elixir
# config/prod.exs — strip contracts entirely from the prod build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  invariants: :purge,
  checks: :purge
```

- **`true` (default)** — compiled in, runtime-togglable, evaluated by default.
- **`false`** — compiled in, runtime-togglable, *not* evaluated by default.
- **`:purge`** — not compiled at all. Zero overhead. No contract docs.

When compiled with `true` or `false`, contracts can be flipped at runtime
via `Bond.Config` — `Bond.Config.disable(:preconditions)` /
`Bond.Config.enable(:preconditions)`, no recompilation needed. (Setting
`Application.put_env(:bond, …)` after the first contracted call has no
effect — the runtime state is cached; use `Bond.Config`.) `:purge` is the
only setting with no runtime presence (the code isn't there).

For finer control, the `:overrides` config lets you set per-module rules.
See the `Bond` moduledoc's "Conditional compilation" and "Per-module
overrides" sections for the full story.

## Testing contract violations

For testing that a contract IS raised (or that a specific contract isn't),
`Bond.Test` provides ExUnit helpers:

```elixir
defmodule MyAppTest do
  use ExUnit.Case
  use Bond.Test

  alias MyApp.Math

  test "sqrt rejects negative input" do
    assert_precondition_violation(Math.sqrt(-1), label: :non_negative_x)
  end
end
```

See `Bond.Test` for `assert_precondition_violation/2`,
`assert_postcondition_violation/2`, and `assert_check_violation/2`.

## Next steps

- The `Bond` moduledoc has the full reference, including the
  [`@invariant`](Bond.html#module-invariant-for-struct-modules) section
  for module-wide constraints on every instance of a struct, and the
  [Property-based testing](Bond.html#module-property-based-testing)
  section for using contracts as oracles with StreamData.
- The [Contracts in a Concurrent World](contracts-and-concurrency.md) guide
  covers `old`, race conditions, how to design contracts for stateful
  processes, and how `@invariant` strengthens the pure-state-struct pattern.
- The [FAQ](faq.md) answers common questions: "why contracts when I have
  ExUnit?", "how does Bond compare to Norm?", "when does Bond check
  invariants?", "how does Bond compose with StreamData?", and so on.
