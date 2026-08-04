# Bond

[![CI](https://github.com/jvoegele/bond/actions/workflows/ci.yml/badge.svg)](https://github.com/jvoegele/bond/actions/workflows/ci.yml)

<!-- README START -->

Design by Contract for Elixir.

A contract is a plain Elixir expression attached to a function and checked at
runtime:

```elixir
defmodule Account do
  use Bond

  defstruct [:balance]

  @pre sufficient_funds: amount <= account.balance
  @post debited: result.balance == account.balance - amount
  def withdraw(%Account{} = account, amount) do
    %{account | balance: account.balance - amount}
  end
end
```

`@pre` states what the caller must satisfy. `@post` states what the function
promises in return — and it mentions `result`, the return value, which a `when`
guard cannot do at all.

When a contract fails, Bond tells you which one, and on what input:

```
# Account.withdraw(%Account{balance: 100}, 250)
** (Bond.PreconditionError) precondition failed for call to Account.withdraw/2
|   at: lib/account.ex:6
|   label: :sufficient_funds
|   assertion: amount <= account.balance
|   binding: [account: %Account{balance: 100}, amount: 250]
```

That is the division of labour worth keeping in mind: **guards say what a
function accepts; contracts say what it promises** — the relationships between
arguments, and between arguments and the result. Guards and patterns stay
exactly where they are; contracts are an additive layer over them, not a
replacement (see
[Should I remove guards when I add contracts?](guides/faq.md#should-i-remove-guards-and-pattern-matches-when-i-add-contracts)).

## What only a contract can say

The example above is deliberately small. The reason to reach for contracts is
the properties that have nowhere else to live:

```elixir
defmodule Cart do
  use Bond

  defstruct items: [], total_cents: 0

  # Must hold before and after every public function in this module.
  # `subject` is the struct instance being checked.
  @invariant total_matches_items:
               subject.total_cents == Enum.sum(Enum.map(subject.items, & &1.cents))

  # `old(...)` snapshots a value before the call, so a postcondition can relate
  # the state afterwards to the state before.
  @post added_one: length(result.items) == length(old(cart.items)) + 1
  def add_item(%Cart{} = cart, item) do
    %{cart | items: [item | cart.items]}
  end
end
```

`add_item/2` forgot to update `total_cents`. No guard, typespec, or pattern
would catch that — but the invariant is checked around every public function, so
it fails on the way out and hands you the offending state:

```
# Cart.add_item(%Cart{}, %{sku: "A", cents: 500})
** (Bond.InvariantError) invariant violated around Cart.add_item/2
|   at: lib/cart.ex:7
|   label: :total_matches_items
|   assertion: subject.total_cents == Enum.sum(Enum.map(subject.items, & &1.cents))
|   binding: [subject: %Cart{items: [%{cents: 500, sku: "A"}], total_cents: 0}]
```

Three things there are beyond a guard's reach: a **class invariant** enforced at
every boundary of the module, a postcondition relating the result to the
**pre-call state** via `old/1`, and a failure message naming the property that
broke and the value that broke it. Contracts also double as
[property-test oracles](guides/testing-contracts.md) and can be
[inherited from a behaviour](guides/contract-inheritance.md), so the same
statement is checked in every implementation.

## When not to reach for Bond

Volunteering the boundary is more useful than overselling:

  * **Anything a guard already enforces.** `@pre is_binary(name)` next to
    `when is_binary(name)` is documentation, not enforcement — the guard runs
    first, so the precondition can never fire. Write the guard; add the `@pre`
    only if you want it in the generated docs.
  * **Hot paths.** Contracts cost real nanoseconds per call. They can be
    switched off at runtime, or removed at compile time so that not even the
    check remains (the `:purge` setting, covered under
    [Configuring Contracts](guides/configuration.md)). The usual
    answer is to leave them on in dev and test and purge them in production —
    see the [Overhead](guides/overhead.md) guide for measured figures.
  * **Type-shaped constraints alone.** If all you want to say is "this is an
    integer", a typespec plus Dialyzer says it at compile time and costs nothing
    at runtime. Contracts earn their keep on the *relationships* types cannot
    express.

Bond is an implementation of the
[Design by Contract](https://en.wikipedia.org/wiki/Design_by_contract)
methodology (also called _programming by contract_), introduced by Bertrand
Meyer with the Eiffel language. See the
[About](guides/about.md) guide for background.

## Installation

Add `bond` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 1.13"}
  ]
end
```

Then run `mix deps.get`. Bond's only dependency is `:telemetry`; `:stream_data`
is optional and needed solely for the property-testing macros. Bond starts no
processes and adds nothing to your supervision tree — `use Bond` is compile-time
machinery, and the runtime side is plain function calls.

## Where to go from here

Bond does more than the two examples above. The rest of the documentation is
organised around the questions that tend to arrive in this order:

  * **Still evaluating?** The examples above are the argument, and
    [When not to reach for Bond](#module-when-not-to-reach-for-bond) is the other
    half of it. Nothing else is needed to judge whether Bond is for you.
  * **[Getting Started](guides/getting-started.md)** — a walkthrough that builds
    one example at a time. The place to go next.
  * **[Writing Contracts](guides/writing-contracts.md)** — the full reference for
    `@pre`, `@post`, `check/1`, `old/1`, the assertion language, and how contracts
    appear in your generated docs.
  * **[Writing sound assertions](guides/writing-sound-assertions.md)** — the
    mistakes that make a contract silently vacuous, and how to avoid them.
  * **[Invariants](guides/invariants.md)** — properties of a struct, checked at
    every boundary of its module.
  * **[Reusable contracts](guides/reusable-contracts.md)** — naming a contract
    once and applying it in several places.
  * **[Contract inheritance](guides/contract-inheritance.md)** — contracts declared
    on a `Bond.Behaviour` callback or a `Bond.Protocol` function, enforced in every
    implementation.
  * **[Contracts in a concurrent world](guides/contracts-and-concurrency.md)** —
    process state, `Bond.Server`, and what contracts can and cannot promise across
    processes.
  * **[Testing contracts](guides/testing-contracts.md)** — asserting violations,
    and using contracts as property-test oracles.
  * **[Configuring Contracts](guides/configuration.md)** — turning
    kinds on and off per environment and per module, and removing them entirely.
  * **[Overhead](guides/overhead.md)** — what contracts cost, measured per call.
  * **[Telemetry](guides/telemetry.md)** — the assertion-failure event.
  * **[Stability](guides/stability.md)** and
    **[Public API surface](guides/public-api.md)** — what semver covers.
  * **[FAQ](guides/faq.md)** — including how contracts relate to guards and typespecs.

<!-- README END -->

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/bond/Bond.html) and be found at
<https://hexdocs.pm/bond/Bond.html>.
