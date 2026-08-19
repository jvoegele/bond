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
  @post conserved: result.from.balance + result.to.balance == from.balance + to.balance
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

### Result-only contracts

When the same return-value guarantee applies across functions of **different arities**,
declare the contract with an explicit empty parameter list:

```elixir
defcontract gate_result() do
  @post {:ok, :cleared} <~ result or
          ({:error, :validation_failed, errs} when is_list(errs)) <~ result
end
```

A zero-argument contract is **arity-agnostic**: `@apply_contract :gate_result` works
on a function of any arity. The wrapper still forwards the applying function's actual
arguments to the original implementation — only the postcondition is constrained, and
only through `result`.

```elixir
@apply_contract :gate_result
def can_encode_previews?(game_film), do: …        # arity 1

@apply_contract :gate_result
def can_encode?(game_film, exchange_file), do: …  # arity 2
```

The explicit `()` is required — `defcontract gate_result do … end` (no parens)
raises a `CompileError` pointing at the `()` form. Preconditions are not meaningful
in a zero-argument contract (no argument names to reference) and are rejected at
compile time by the reference validator.

## Applying a contract

`@apply_contract` immediately precedes the function it constrains, like `@pre`:

  * `@apply_contract :name` — a contract defined in the **same** module.
  * `@apply_contract {Module, :name}` — a contract defined in **another**
    module, read through that module's generated reflection at compile time.

```elixir
defmodule Bookkeeping do
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
implementation's parameters rebind to its callback's names. The contract's declared
arity must match the function's arity; a mismatch is a compile error that lists the
available arities. The one exception is a zero-argument `defcontract name()`, which
is arity-agnostic and applies to any function regardless of arity (see
[Result-only contracts](#result-only-contracts) above).

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

## In a behaviour declaration

`defcontract` and `@apply_contract` are available in any `use Bond.Behaviour`
module, letting the behaviour author name a shared agreement once and reference it
from multiple callbacks:

```elixir
defmodule Accounts do
  use Bond.Behaviour

  defcontract ledger_op(account, amount) do
    @pre positive: amount > 0
    @post non_negative: result.balance >= 0
  end

  @apply_contract :ledger_op
  @callback withdraw(account :: map(), amount :: number()) :: map()

  @apply_contract :ledger_op
  @callback deposit(account :: map(), amount :: number()) :: map()
end
```

Implementers see no difference — `use Bond, behaviours: [Accounts]` inherits
`withdraw/2` and `deposit/2` with the same canonical argument names and assertions
as if the contracts had been written with plain `@pre`/`@post`.

A zero-argument contract is particularly useful when several callbacks with
**different arities** all share the same return-value guarantee:

```elixir
defmodule FileStore do
  use Bond.Behaviour

  defcontract valid_key() do
    @post is_binary(result)
  end

  @apply_contract :valid_key
  @callback read(bucket :: term(), key :: String.t()) :: String.t()

  @apply_contract :valid_key
  @callback write(bucket :: term(), key :: String.t(), value :: term()) :: String.t()
end
```

The behaviour module emits `__bond_named_contracts__/0` when it defines named
contracts, so other modules can reference them via `@apply_contract {FileStore, :valid_key}`.

## In a protocol declaration

The same syntax works inside a `defprotocol` that uses `Bond.Protocol`:

```elixir
defprotocol Serializable do
  use Bond.Protocol

  defcontract valid_payload() do
    @post is_binary(result) and byte_size(result) > 0
  end

  @apply_contract :valid_payload
  @spec encode(t) :: binary()
  def encode(data)

  @apply_contract :valid_payload
  @spec encode_compressed(t) :: binary()
  def encode_compressed(data)
end
```

Every implementation is wrapped uniformly at dispatch with the contract attributed
to the protocol, exactly as if `@post` had been written directly on each function.

## Strengthening inherited contracts

An implementation can go beyond what its behaviour promises by applying a
zero-argument contract on an `@impl` function. The applied contract's
postconditions are added alongside the inherited ones — equivalent to writing
`@post_strengthen` but named and reusable:

```elixir
defmodule Audited do
  use Bond

  defcontract audit_trail() do
    @post audit_written?(result)
  end
end

defmodule AuditedAccount do
  use Bond, behaviours: [Accounts]  # Accounts @post: result.balance >= 0

  @apply_contract {Audited, :audit_trail}
  @impl true
  def withdraw(account, amount), do: ...
end
```

`AuditedAccount.withdraw/2` enforces both the inherited `non_negative` postcondition
and the `audit_written?` assertion. The inherited `@pre` and canonical argument names
from `Accounts` remain in force.

Only **zero-argument** contracts may be combined with behaviour inheritance — they
reference only `result` and so do not conflict with the inherited contract's canonical
argument vocabulary. A non-zero-arg contract alongside a behaviour contract is a
compile error; use `@post_strengthen` directly when you need to add an
argument-referencing strengthening.

## Scope and non-goals

Two relationships are reported as clear compile errors:

  * **Combining a non-zero-arg contract with behaviour inheritance.** A zero-arg
    (result-only) contract can be combined with inheritance — see
    [Strengthening inherited contracts](#strengthening-inherited-contracts) above.
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
