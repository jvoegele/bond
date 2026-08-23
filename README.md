# Bond

[![CI](https://github.com/jvoegele/bond/actions/workflows/ci.yml/badge.svg)](https://github.com/jvoegele/bond/actions/workflows/ci.yml)

<!-- README START -->

Design by Contract for Elixir.

A contract is a plain Elixir expression attached to a function and checked at
runtime. Here is one that says money is neither created nor destroyed:

```elixir
defmodule Account do
  defstruct [:owner, :balance]
end

defmodule Ledger do
  use Bond

  @pre sufficient_funds: amount <= from.balance
  @post conserved: result.from.balance + result.to.balance == from.balance + to.balance
  def transfer(%Account{} = from, %Account{} = to, amount) do
    %{
      from: %{from | balance: from.balance - amount},
      to: %{to | balance: to.balance + amount}
    }
  end
end
```

`@pre` declares a **precondition** — what the caller must satisfy for the call to
be valid. `@post` declares a **postcondition** — what the function promises in
return, provided the precondition held. A postcondition can mention `result`, the
function's return value, which a `when` guard cannot do at all. (Guards keep the
jobs only they can do — dispatch, and standing in for types — see
[Should I remove guards when I add contracts?](guides/faq.md#should-i-remove-guards-and-pattern-matches-when-i-add-contracts).)

Note what `conserved` is *not*: a restatement of the body. The body moves money;
the contract states the law the movement must obey. So when someone later adds a
transfer fee and takes it out of the sender only, the arithmetic still looks
plausible — and the contract fails:

```
# Ledger.transfer(ana, bo, 200)   # after a 1% fee is deducted from the sender
** (Bond.PostconditionError) postcondition failed in Ledger.transfer/3
|   at: lib/ledger.ex:9
|   label: :conserved
|   assertion: result.from.balance + result.to.balance == from.balance + to.balance
|   binding: [
  amount: 200,
  from: %Account{owner: "ana", balance: 1000},
  result: %{
    to: %Account{owner: "bo", balance: 250},
    from: %Account{owner: "ana", balance: 798}
  },
  to: %Account{owner: "bo", balance: 50}
]
```

The failure names the property that broke, and hands you both states to compare.

## Beyond preconditions and postconditions

`@pre` and `@post` constrain one call at a time. The rest of Bond is about
getting more out of the same statements — enforcing them across a whole module,
across every implementation of a behaviour, and against inputs you never wrote
down.

**Checked at every entrance and exit of a module.** An `@invariant` is a property
of the struct rather than of any one call, so Bond checks it around every public
function — including the ones a colleague adds next year:

```elixir
defmodule Cart do
  use Bond

  defstruct items: [], total_cents: 0

  @invariant total_matches_items:
               subject.total_cents == Enum.sum(Enum.map(subject.items, & &1.cents))

  @post added_one: length(result.items) == length(cart.items) + 1
  def add_item(%Cart{} = cart, item) do
    %{cart | items: [item | cart.items]}
  end
end
```

`add_item/2` forgot to update `total_cents`. Nothing in the function is wrong on
its own terms, and no guard, typespec, or pattern would object — but the
invariant is checked on the way out:

```
# Cart.add_item(%Cart{}, %{sku: "A", cents: 500})
** (Bond.InvariantError) invariant violated around Cart.add_item/2
|   at: lib/cart.ex:6
|   label: :total_matches_items
|   assertion: subject.total_cents == Enum.sum(Enum.map(subject.items, & &1.cents))
|   binding: [subject: %Cart{items: [%{cents: 500, sku: "A"}], total_cents: 0}]
```

**Checked in every implementation of a behaviour.** Declare the contract once, on
the callback, and every implementing module enforces it — without a line of
contract code in any of them:

```elixir
defmodule Paginator do
  use Bond.Behaviour

  @post never_over_limit: length(result) <= limit
  @callback fetch(page :: pos_integer(), limit :: pos_integer()) :: list()
end

defmodule LegacyPages do
  use Bond, behaviours: [Paginator]

  @impl true
  def fetch(page, _limit), do: Enum.map(1..50, &{page, &1})   # ignores limit
end
```

```
** (Bond.PostconditionError) postcondition (inherited from Paginator) failed in LegacyPages.fetch/2
|   at: lib/paginator.ex:4
|   label: :never_over_limit
```

The violation is attributed to the behaviour that declared it, and points at the
line in *that* file. A promise made by an interface, kept by everything that
implements it.

**Checked against inputs you never thought of.** The contracts you have already
written are a specification, so they can serve as the oracle for property-based
testing. You supply generators; Bond supplies the expected behaviour:

```elixir
defmodule Roots do
  use Bond

  @pre non_negative: x >= 0.0
  @post never_negative: result >= 0.0
  @post shrinks_above_one: (x > 1.0) ~> (result < x)
  def sqrt(x), do: :math.sqrt(x)
end
```

```elixir
# in test/roots_test.exs
use Bond.PropertyTest

contract_holds &Roots.sqrt/1, args: [StreamData.float(min: 0.0)]
```

That runs `sqrt/1` against a stream of generated floats and fails if any
precondition, postcondition, or `check` is violated, with StreamData shrinking to
a minimal counterexample. Those two postconditions are the whole oracle — there
is no separate model of "expected output" to write or keep in step, because the
contract already said it. (`~>` is implication: `shrinks_above_one` asserts
nothing unless `x > 1.0`.) See
[Testing Contracts](guides/testing-contracts.md) for `probe_contract/2`, which
reads the boundaries out of your `@pre` and aims generators at them, and
`invariants_hold/2`, which throws random *sequences* of operations at a struct.

## You choose what they cost

Contracts are checked at runtime, so they are not free — the
[Overhead](guides/overhead.md) guide publishes measured per-call figures. What
makes that affordable is that the decision is yours, per environment and per
contract kind:

```elixir
# config/prod.exs
config :bond, preconditions: :purge, postconditions: :purge, invariants: :purge
```

Purged contracts are not compiled in at all — there is no check to skip, and the
function runs exactly as if the contract had never been written. Your published
documentation still shows it, because `mix docs` runs in `:dev` where contracts
are enabled: the contract stays part of the module's stated interface even in
builds that do not check it.

Between "on" and "purged" there is a third setting that compiles the check in but
leaves it switched off, so a release can run with contracts inert and have them
enabled from a remote console while a problem is being diagnosed. See
[Configuring Contracts](guides/configuration.md).

Contracts are normally on in dev and test. What you keep in production is a
separate decision — often nothing, often just the preconditions, which are the
cheapest kind and the only one that tells you a *caller* is at fault. Either way,
that is why it is worth writing the expensive, interesting ones.

## Installation

Add `bond` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 1.15"}
  ]
end
```

Then run `mix deps.get`. Bond's only dependency is `:telemetry`; `:stream_data`
is optional and needed solely for the property-testing macros. Bond starts no
processes and adds nothing to your supervision tree — `use Bond` is compile-time
machinery, and the runtime side is plain function calls.

## Where to go from here

Bond does more than the examples above. The rest of the documentation is
organised around the questions that tend to arrive in this order:

  * **Still evaluating?** The examples above are the argument. The
    [FAQ](guides/faq.md) answers the comparisons that usually decide it —
    ["What does Bond do that typespecs don't?"](guides/faq.md#what-does-bond-do-that-typespecs-don-t)
    and
    ["Should I remove guards when I add contracts?"](guides/faq.md#should-i-remove-guards-and-pattern-matches-when-i-add-contracts).
  * **[Getting Started](guides/getting-started.md)** — a walkthrough that builds
    one example at a time. The place to go next.
  * **[Writing Contracts](guides/writing-contracts.md)** — the full reference for
    `@pre`, `@post`, `check/1`, `old/1`, `forall`/`exists`, the assertion
    language, and how contracts appear in your generated docs.
  * **[Cheatsheet](guides/cheatsheet.cheatmd)** — every form Bond gives you on
    one page, once you know what you're looking for.
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
  * **[About](guides/about.md)** and **[History](guides/history.md)** — Design by
    Contract as Bertrand Meyer introduced it with Eiffel, what Bond keeps and
    drops from it, and the Elixir libraries that came before.

<!-- README END -->

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on HexDocs at <https://hexdocs.pm/bond>.
