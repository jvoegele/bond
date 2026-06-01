# Contract Inheritance for Behaviours

A behaviour is a promise about a *family* of implementations. Design by
Contract gives that promise teeth: declare `@pre`/`@post` on a behaviour's
`@callback`s and Bond enforces them on every module that implements the
behaviour. This is the Liskov Substitution Principle made executable — any
implementation is substitutable for the abstraction precisely because it
honours the abstraction's contract.

## The shape

The behaviour author writes contracts directly above the `@callback` they
constrain, using `Bond.Behaviour`:

```elixir
defmodule Ledger do
  use Bond.Behaviour

  @pre positive_amount: amount > 0
  @post non_negative: result >= 0
  @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
end
```

The implementer opts in with `use Bond, behaviours: [Ledger]` and just writes
ordinary functions:

```elixir
defmodule BankAccount do
  use Bond, behaviours: [Ledger]

  @impl true
  def withdraw(balance, amount) when amount <= balance, do: balance - amount
end
```

`BankAccount.withdraw/2` now enforces `amount > 0` on entry and `result >= 0`
on exit, even though those contracts are written nowhere in `BankAccount`. A
violation is attributed to its source:

```
** (Bond.PreconditionError) precondition (inherited from Ledger) failed for call to BankAccount.withdraw/2
|   at: lib/ledger.ex:5
|   label: :positive_amount
|   assertion: amount > 0
|   binding: [amount: 0, balance: 100]
```

The MFA names the implementing module (`BankAccount.withdraw/2`); the location
and the `(inherited from Ledger)` clause point back at the contract's origin.
The `Bond.PreconditionError` struct carries a `:source_behaviour` field, and
the `[:bond, :assertion, :failure]` telemetry metadata carries it too.

## `use Bond, behaviours:` declares the behaviour for you

Passing `behaviours: [Ledger]` emits `@behaviour Ledger` on your behalf, so
Elixir's own missing-callback and arity checks apply and `@impl true` works.
You do not write a separate `@behaviour Ledger`.

## Positional rebind: the contract names the arguments

Contract expressions reference the **callback's** argument names — `balance`
and `amount` above. Those become the canonical names for each position, and
your implementation's parameters are rebound to them positionally. You are
free to name your parameters whatever you like:

```elixir
@impl true
def withdraw(bal, amt) when amt <= bal, do: bal - amt
```

`@pre amount > 0` still checks the second argument (`amt`), because the
contract binds by position, not by your chosen name. The same holds across
every clause of a multi-clause implementation — one inherited contract applies
uniformly to all of them.

## Immutable inheritance (v1)

Inherited contracts are **immutable**. An implementation may not weaken,
strengthen, or add to them. Attaching `@pre`/`@post` to an implementation
function whose `{name, arity}` matches an inherited contract is a compile
error:

```elixir
defmodule BankAccount do
  use Bond, behaviours: [Ledger]

  @impl true
  @pre amount > 100   # ** (CompileError) ... may not declare its own @pre/@post ...
  def withdraw(balance, amount), do: balance - amount
end
```

This is a deliberate soundness boundary, not a missing feature:

  * **Strengthening a precondition breaks substitutability.** If an
    implementation could add its own `@pre` (conjoined with `AND`), a caller
    that satisfies the abstraction's precondition could still be rejected by a
    particular implementation — so the implementation would *not* be
    substitutable for the abstraction. The Liskov Substitution Principle
    requires preconditions to only ever *weaken* down a hierarchy.
  * **Adding a postcondition is refinement by the back door.** It would be
    sound, but Bond reserves that meaning for a future Eiffel-style refinement
    feature (`@pre_else` / `@post_then`) so that giving plain impl-level
    `@pre`/`@post` a different meaning now doesn't create migration debt later.

The sanctioned escape hatch for an implementation-specific assertion is
`check/1` in the function body — it is independent of the contract chain:

```elixir
@impl true
def withdraw(balance, amount) do
  check sufficient_funds: amount <= balance
  balance - amount
end
```

Helper functions and public functions *outside* the behaviour keep ordinary
`@pre`/`@post`, and struct `@invariant`s compose untouched.

## Rules to know

  * **Multiple behaviours, same `{name, arity}`.** If two behaviours in your
    `behaviours:` list constrain the same operation, their contracts must be
    *structurally identical*. Conjoining would be unsound and picking one
    arbitrarily would be surprising, so a genuine difference is a compile
    error.
  * **Only Bond behaviours.** A module passed to `behaviours:` must
    `use Bond.Behaviour`. Passing a plain behaviour (or a typo) is a compile
    error — declare a plain behaviour with `@behaviour` as usual.
  * **Optional callbacks** are enforced only if your module actually defines
    them.
  * **Matching is by `{name, arity}` only**, independent of whether you wrote
    `@impl true`.
  * **Name your callback arguments.** Contracts reference callback argument
    names, so write `@callback f(x :: integer) :: integer`, not
    `@callback f(integer) :: integer`. Unnamed positions can't be referenced
    by a contract.

## What's not here yet

v1 is the immutable model only. Eiffel-style contravariant/covariant
*refinement* (`@pre_else` / `@post_then`) and protocol contracts are tracked
as separate follow-ups; the immutable model is forward-compatible with both.
`use Bond, behaviours: […]` is the only entry point — there is no
`use TheBehaviour` shortcut in v1.
