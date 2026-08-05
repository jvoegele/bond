# Getting Started

This guide walks you through adding Bond to a project, writing your first
contract, and the most common patterns you'll encounter.

For the full reference, see the [Writing Contracts](writing-contracts.md)
guide and the guides it links to.

## Installation

Add `bond` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 1.14"}
  ]
end
```

Then run `mix deps.get`.

## Your first contract

`use Bond` in any module to enable `@pre`, `@post`, `@invariant`, and `check/1`.
A `@pre` declares a **precondition** — something the caller must satisfy for the
call to be valid:

```elixir
defmodule Account do
  use Bond

  defstruct [:owner, :balance]

  @pre positive_amount: amount > 0
  def withdraw(%Account{} = account, amount) do
    %{account | balance: account.balance - amount}
  end
end
```

`Account.withdraw(%Account{owner: "ana", balance: 100}, 30)` returns an account
with a balance of `70`. A negative amount raises instead, and the message names
the clause that failed and shows everything that was in scope when it did:

```text
** (Bond.PreconditionError) precondition failed for call to Account.withdraw/2
|   at: lib/account.ex:6
|   label: :positive_amount
|   assertion: amount > 0
|   binding: [account: %Account{owner: "ana", balance: 100}, amount: -30]
```

## Adding a postcondition

A `@post` declares a **postcondition** — what the function guarantees in
return, provided the precondition held. Postconditions are evaluated after the
body, and see the function's parameters plus a `result` variable bound to the
return value:

```elixir
@pre positive_amount: amount > 0
@post non_negative: result.balance >= 0
def withdraw(%Account{} = account, amount) do
  %{account | balance: account.balance - amount}
end
```

Nothing in this function prevents an overdraft, and nothing in its signature
would warn you. The postcondition does:

```text
** (Bond.PostconditionError) postcondition failed in Account.withdraw/2
|   at: lib/account.ex:7
|   label: :non_negative
|   assertion: result.balance >= 0
|   binding: [
  account: %Account{owner: "ana", balance: 20},
  amount: 50,
  result: %Account{owner: "ana", balance: -30}
]
```

Note what the postcondition says that a guard cannot: it constrains the *return
value*. Guards only see the arguments, and by the time the balance has gone
negative the arguments are long past.

The two kinds also assign blame differently, which is most of what you are
deciding when you write one down. A failed precondition says the **caller**
asked for something it wasn't entitled to; a failed postcondition says the
**function** broke its own promise. Overdrafts can be framed either way, and
the next section takes the other option.

## Labelled assertions

A single `@pre` or `@post` may hold several labelled assertions as a keyword
list. The label appears in the error message, so a failure names the clause
rather than the whole annotation:

```elixir
@pre positive_amount: amount > 0,
     sufficient_funds: amount <= account.balance
def withdraw(%Account{} = account, amount) do
  %{account | balance: account.balance - amount}
end
```

```text
** (Bond.PreconditionError) precondition failed for call to Account.withdraw/2
|   at: lib/account.ex:6
|   label: :sufficient_funds
|   assertion: amount <= account.balance
|   binding: [account: %Account{owner: "ana", balance: 20}, amount: 50]
```

This is the same overdraft as the previous section, caught one step earlier and
blamed on the caller instead of the function. Note what it did to the
postcondition: with `sufficient_funds` in force, `non_negative` can no longer
fail, and an assertion that can never fail is worth deleting rather than
keeping — see [Writing sound assertions](writing-sound-assertions.md).

Labels can be atoms (when they're valid Elixir identifiers) or strings (for
phrases with spaces or punctuation):

```elixir
@post "balance is a whole number of cents": is_integer(result.balance)
```

## Predicates and operators

The `Bond.Predicates` module is automatically imported inside assertion
expressions. Two operators are especially useful in contracts:

- `~>` — logical implication. `(p ~> q)` means "if `p` then `q`".
- `<~` — pattern match. `(pattern <~ expression)` is `match?(pattern, expression)`.

```elixir
@post no_fee_below_limit: (amount < 100) ~> (result.fee == 0)
@post {:ok, _} <~ result
```

Implication is what lets one contract cover several shapes of input without
asserting anything about the ones it doesn't apply to: `no_fee_below_limit`
says nothing at all when `amount` is 100 or more.

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
    :math.pow(Enum.product(samples), 1 / length(samples))
  end
end

defmodule Roster do
  use Bond

  @pre has_admin: exists(u <- users, u.role == :admin)
  def authorize(users), do: Enum.map(users, &grant/1)
end
```

Both preconditions state something a type cannot: `geometric_mean/1` is
undefined for a negative sample (the product's root is complex), and a roster
with nobody able to authorize is a roster that will deadlock the moment someone
needs approval.

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
** (Bond.PreconditionError) precondition failed for call to Roster.authorize/1
|   label: :has_admin
|   assertion: exists(u <- users, u.role == :admin)
|   counterexample: no element of `users` satisfies `u.role == :admin` (3 elements)
|   binding: [users: [%{role: :user}, %{role: :guest}, %{role: :user}]]
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
  [Deciding what runs in production](#deciding-what-runs-in-production))
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

See the [Invariants](invariants.md) guide for head-shape detection,
multi-struct heads, and per-module configuration.

## Invariants for process state

A struct `@invariant` constrains a *value*. To constrain the state of a running
`GenServer` — checked after every callback, catching inline state mutations a
struct invariant would miss — add `use Bond.Server` and declare a
`@state_invariant`. A `@transition_invariant` goes further, relating the prior
state (`old_state`) to the next (`new_state`) across each transition:

```elixir
defmodule Counter do
  use GenServer
  use Bond.Server

  @state_invariant      non_negative: state.count >= 0
  @transition_invariant monotonic:    new_state.count >= old_state.count

  @impl true
  def init(n), do: {:ok, %{count: n}}

  @impl true
  def handle_call(:inc, _from, state), do: {:reply, :ok, %{state | count: state.count + 1}}

  @impl true
  def handle_cast(:dec, state), do: {:noreply, %{state | count: state.count - 1}}
end
```

Because the checks run inside the serialized server process, they are race-free —
even a temporal property like "the counter never decreases". A `:dec` cast that
drops `count` below the previous value raises `Bond.InvariantError`. See
`Bond.Server` and the
[Contracts in a Concurrent World](contracts-and-concurrency.md) guide.

## Deciding what runs in production

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

That is one choice of several. Keeping preconditions on — the cheapest kind,
and the only one that catches a *caller's* bug — while purging the rest is a
common middle ground; see
[Choosing what runs in production](configuration.md#choosing-what-runs-in-production).

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
See [Configuring Contracts](configuration.md) for the full story.

## Testing contract violations

For testing that a contract IS raised (or that a specific contract isn't),
`Bond.Test` provides ExUnit helpers:

```elixir
defmodule MyApp.AccountTest do
  use ExUnit.Case
  use Bond.Test

  alias MyApp.Account

  test "withdrawing more than the balance is rejected" do
    account = %Account{owner: "ana", balance: 20}

    assert_precondition_violation(Account.withdraw(account, 50),
      label: :sufficient_funds
    )
  end
end
```

Passing `label:` matters more than it looks: without it the test passes as long
as *some* precondition fired, which would still be green if `positive_amount`
started rejecting the call for an unrelated reason.

`Bond.Test` has one such macro per contract kind (preconditions, postconditions,
`check`s, struct invariants, and `Bond.Server` state/transition invariants), and you
can target a specific clause by `label`. For the
complete testing story — these example-based helpers *and* property-based testing,
where contracts act as the oracle for random inputs — see the
[Testing Contracts](testing-contracts.md) guide.

## Next steps

- The [Writing Contracts](writing-contracts.md) guide is the full reference for
  the annotations and the assertion language, and [Invariants](invariants.md)
  covers module-wide constraints on every instance of a struct.
- The [Testing Contracts](testing-contracts.md) guide covers the whole
  testing surface — `Bond.Test`'s example-based assertions and
  `Bond.PropertyTest`'s `contract_holds/2`, `probe_contract/2`, and
  `invariants_hold/2` — and when to reach for each.
- The [Contract Inheritance](contract-inheritance.md) guide shows how a
  behaviour or protocol can declare `@pre`/`@post` once and have every
  implementation enforce them, and how an implementation may refine what it
  inherits.
- The [Reusable Contracts](reusable-contracts.md) guide shows how to bundle
  `@pre`/`@post` under a name with `defcontract` and share it across functions
  (in the same module or across modules) with `@apply_contract`.
- The [Contracts in a Concurrent World](contracts-and-concurrency.md) guide
  covers `old`, race conditions, how to design contracts for stateful
  processes, and how `@invariant` strengthens the pure-state-struct pattern.
- The [FAQ](faq.md) answers common questions: "why contracts when I have
  ExUnit?", "how does Bond compare to Norm?", "when does Bond check
  invariants?", "how does Bond compose with StreamData?", and so on.
