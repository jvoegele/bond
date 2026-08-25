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
    {:bond, "~> 1.17"}
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

> #### If your contracts do nothing, check for `use Bond` {: .warning}
>
> Without it, `@pre`/`@post` fall through to `Kernel.@` and become ordinary
> module attributes. None of the resulting errors mentions Bond, so the cause is
> not obvious from any of them:
>
>   * an assertion that references a parameter — `error: undefined variable "x"`
>   * a `@post` referencing `result` — `error: undefined variable "result"`
>   * an assertion referencing **nothing** — compiles, enforces nothing, and
>     warns only `module attribute @pre was set but never used`
>
> The third is the one that can pass unnoticed, though `--warnings-as-errors`
> catches it and most real assertions name a parameter. If you see any of these
> around a contract, check the module has `use Bond` before looking anywhere
> else.

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

You could already write these with `Enum.all?/2` and `Enum.any?/2`. What you
would lose is the diagnosis — when one of those fails, Bond can only tell you
the *whole* expression was false. A quantifier names **which element** broke the
contract:

```
** (Bond.PreconditionError) precondition failed for call to Stats.geometric_mean/1
|   label: :all_positive
|   assertion: forall(x <- samples, x > 0)
|   counterexample: element at index 3 (-2) does not satisfy `x > 0`
|   binding: [samples: [5, 2, 8, -2]]
```

`exists` instead reports that no element satisfied the predicate.

One thing to unlearn straight away: despite the syntax, the trailing expression
is the **predicate being asserted**, not a filter — `forall(x <- items, x > 0)`
means "for all `x` in `items`, `x > 0`", not "for the `x` in `items` where
`x > 0`". There is no `do` block, and the right-hand side of `<-` is a plain
`Enumerable`, not a StreamData generator.

See [Quantified assertions](writing-contracts.md#quantified-assertions) for the
rest: where they may appear, nesting, and the rules for quantifying over large
collections and streams.

## `old` expressions in postconditions

For functions that mutate state, a postcondition often needs to compare
the *new* state to the *old* state. The `old/1` macro snapshots a value
before the function body runs:

```elixir
@post incremented: current_turn() == old(current_turn()) + 1
def take_turn do
  Process.put(:turn, current_turn() + 1)
  :ok
end
```

`old` is only available inside `@post`, and Bond resolves every `old(...)`
expression at the start of function execution. It is meaningful only for state
that actually changes: for an immutable parameter `x`, `old(x)` and `x` are the
same value.

See [`old` expressions](writing-contracts.md#old-expressions) for the full
semantics, and [Contracts in a Concurrent World](contracts-and-concurrency.md)
for what happens when the snapshotted state is shared across processes — where
another process can race between the snapshot and the post-check.

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
struct invariant would miss — add `use Bond.Server` **after** `use GenServer` and
declare a `@state_invariant`. A `@transition_invariant` goes further, relating the prior
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
drops `count` below the previous value raises `Bond.InvariantError`.

This `Counter` is the running example of the
[Invariants](invariants.md#stateful-contracts-for-processes) guide, which is the
reference for both annotations; `Bond.Server` is the module reference, and
[Contracts in a Concurrent World](contracts-and-concurrency.md) explains why a
`GenServer` can promise things a shared `Agent` cannot.

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
  covers module-wide constraints on every instance of a struct — both flavours,
  struct and process state.
- [What Should a Contract Say?](what-contracts-say.md) is about the question the
  syntax does not answer — what belongs in an assertion, and why a specification is
  worth writing even when the implementation is one line. [Writing Sound
  Assertions](writing-sound-assertions.md) then covers making one behave the way it
  reads.
- The [Cheatsheet](cheatsheet.cheatmd) puts every form on one page, for once you
  know what you're looking for and just need the syntax.
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
