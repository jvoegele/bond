# Reusable Contracts

Sometimes the same agreement governs several functions. A handful of operations
all require a positive `amount` that fits within an `account`'s balance; a family
of functions all promise a non-negative result. Restating the same `@pre`/`@post`
on each one is repetitive and drifts out of sync.

A **named contract** captures a bundle of `@pre`/`@post` once, under a name, and
applies it to as many functions as you like — in the same module or across
modules:

```elixir
defmodule Money do
  use Bond

  defcontract withdrawal(account, amount) do
    @pre positive: amount > 0
    @pre sufficient: amount <= account.balance
    @post non_negative: result.balance >= 0
  end
end

defmodule Account do
  use Bond

  @apply_contract {Money, :withdrawal}
  def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}
end
```

`Account.withdraw/2` now enforces all three assertions, and a violation names the
contract it came from:

```
** (Bond.PreconditionError) precondition (from contract Money.withdrawal) failed
   for call to Account.withdraw/2
```

A named contract is, in effect, an inherited contract whose source is a
definition rather than a behaviour callback — it shares the *canonical argument
names* and *positional rebinding* model described in the
[Contract Inheritance](contract-inheritance.md) guide.

## Defining a contract

`defcontract name(arg1, arg2, …) do … end` declares a contract. The head is a
canonical signature: its parameter list supplies the **names** the contract's
expressions reference and the **order** they bind in. The body may contain only
`@pre`/`@post` (bare or labelled, exactly as under `use Bond`), and each
expression may reference only the declared arguments — plus `result` (and
`old/1`) in a `@post`:

```elixir
defcontract transfer(from, to, amount) do
  @pre enough: amount <= from.balance
  @pre distinct: from.id != to.id
  @post conserved: result.from.balance + result.to.balance == old(from.balance) + old(to.balance)
end
```

A reference to a name the contract does not declare is a compile error that
points at the offending assertion.

### Overloading by arity

Contracts are identified by `{name, arity}`, so the same name at different
arities are distinct contracts:

```elixir
defcontract positive(x) do
  @pre x > 0
end

defcontract positive(x, floor) do
  @pre x > floor
end
```

There is nothing more to do at the application site — the arity of the function
you apply to selects the overload.

## Applying a contract

`@apply_contract` immediately precedes the function it constrains, like `@pre`:

  * `@apply_contract :name` — a contract defined in the **same** module.
  * `@apply_contract {Module, :name}` — a contract defined in **another**
    module, read through that module's generated reflection at compile time.

```elixir
defmodule Ledger do
  use Bond

  @apply_contract {Money, :withdrawal}      # arity 2 → Money.withdrawal/2
  def withdraw(account, amount), do: debit(account, amount)

  @apply_contract :audited                  # a contract defined in this module
  def post(entry), do: append(entry)

  defcontract audited(entry) do
    @pre has_actor: entry.actor != nil
  end
end
```

The applying function's parameters are rebound to the contract's canonical names
**positionally**, so the function is free to name them differently — `withdraw(acct,
amt)` works against `withdrawal(account, amount)` just as a behaviour
implementation's parameters rebind to its callback's names. The contract's
declared arity must match the function's arity; a mismatch is a compile error
that lists the contract's available arities.

## How failures are attributed

A failing assertion from an applied contract names its source. A cross-module
contract reads `(from contract Money.withdrawal)`; a contract defined in the
failing call's own module abbreviates to `(from contract :withdrawal)`. The
originating `{module, name}` is also available programmatically as the
`:source_contract` field on the error struct, and in the
`[:bond, :assertion, :failure]` telemetry metadata.

## Extending an applied contract

A function may add its own `@pre`/`@post` alongside `@apply_contract`; the added
clauses are **conjoined** with the contract — both must hold:

```elixir
@apply_contract :withdrawal              # withdrawal(account, amount)
@pre whole: amount == trunc(amount)      # also require this
@post logged: audit_written?(result)     # also guarantee this
def withdraw(acct, amt), do: ...
```

Because a named contract carries no substitutability promise (unlike a behaviour
or protocol contract), *strengthening* it this way is sound — adding a requirement
just means this function is stricter than the bare contract. (This is the opposite
of inheritance, where adding a precondition is forbidden precisely because an
implementation *must* stay substitutable for its abstraction.)

Added clauses reference the **contract's** argument names (`amount`, `account`) —
the same canonical vocabulary the contract uses — not the function's own
parameters. A reference to a function parameter (`amt`) is a compile error. A
failure in an added clause is attributed to the **function** (no `from contract …`),
so a message tells contract terms apart from function-specific ones.

## Composing contracts with `include`

A contract can pull in another contract's clauses with `include`, so small, focused
contracts compose into larger ones:

```elixir
defcontract positive(x),         do: (@pre x > 0)
defcontract in_range(v, lo, hi), do: (@pre lo <= v and v <= hi)

defcontract order(item) do
  include positive(item.quantity)
  include in_range(item.discount, 0, 100)
  @post priced: result.total >= 0
end
```

`include name(args)` (local) or `include Module.name(args)` (cross-module) splices
the named contract's `@pre`/`@post` into the host. Each argument is an **expression
over the host's parameters**, substituted into the included contract's clauses — so
`include positive(item.quantity)` enforces `item.quantity > 0`, and error messages
and generated docs show the substituted form. The number of arguments selects the
included overload by arity.

Composition is also how you apply *several* contracts' worth of rules to one
function: compose them into a single contract and apply that (a function still
applies exactly one named contract directly). Includes nest transitively; a contract
that includes the same base along two paths simply checks it twice (harmless —
assertions are side-effect-free and a failure stops at the first). A contract that
includes itself, directly or transitively, is a compile error.

## Scope and non-goals

Two relationships are reported as clear compile errors:

  * **Combining an applied contract with behaviour/protocol inheritance** on the
    *same* function.
  * **Refining** an applied contract with `@pre_weaken`/`@post_strengthen` (the
    *weaken* direction). Additive `@pre`/`@post` covers the common "require more"
    case; weakening a named contract's precondition is not currently supported.

A function applies a single named contract directly; use `include` to combine
several. `@apply_contract` relies on Bond's `@` syntax, so it is unavailable under
`use Bond, at_annotations: false`; `defcontract` (and `include` within it) work in
either mode.

## Named contracts vs. a hand-rolled macro

You can already share contract logic by writing a macro that emits `@pre`/`@post`
(see the FAQ entry on macro-emitted contracts). `defcontract` is the first-class
form of that pattern: it is discoverable, validates references at definition time,
binds positionally so the contract is decoupled from any one function's parameter
names, and attributes failures to the contract by name. Reach for a macro only
when you need to compute assertions dynamically; reach for `defcontract` to share
a fixed agreement.
