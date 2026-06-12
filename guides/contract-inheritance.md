# Contract Inheritance

A behaviour and a protocol are both *promises about a family of
implementations*. Design by Contract gives those promises teeth: declare
`@pre`/`@post` once, on the abstraction, and Bond enforces them across every
implementation — present and future. This is the Liskov Substitution Principle
made executable — an implementation is substitutable for the abstraction
precisely because it honours the abstraction's contract.

Bond offers contract inheritance in two flavours, differing in *where* the
contract is enforced:

  * **[Behaviours](#behaviours)** — contracts ride on a behaviour's
    `@callback`s and are enforced on each implementing module's own function
    clauses. The implementer opts in with `use Bond, behaviours: […]`.
  * **[Protocols](#protocols)** — contracts ride on a `defprotocol`'s functions
    and are enforced once, on dispatch. Implementations need zero Bond
    awareness — no opt-in at all.

The syntax, the reference rules, and the immutability stance are identical
across both; only the enforcement mechanism differs. The shared rules are
collected under [Semantics shared by both flavours](#semantics-shared-by-both-flavours).

## Behaviours

### The shape

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

### `use Bond, behaviours:` declares the behaviour for you

Passing `behaviours: [Ledger]` emits `@behaviour Ledger` on your behalf, so
Elixir's own missing-callback and arity checks apply and `@impl true` works.
You do not write a separate `@behaviour Ledger`.

### Positional rebind: the contract names the arguments

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

### Behaviour-specific rules

  * **Multiple behaviours, same `{name, arity}`.** If two behaviours in your
    `behaviours:` list constrain the same operation, their contracts must be
    *structurally identical*. Conjoining would be unsound and picking one
    arbitrarily would be surprising, so a genuine difference is a compile
    error. Identity is compared on the contract's *source form* — its kind,
    label, and the text of the expression — not its meaning, so `x <= 10` and
    `10 >= x` count as different. Write them identically.
  * **Only Bond behaviours.** A module passed to `behaviours:` must
    `use Bond.Behaviour`. Passing a plain behaviour (or a typo) is a compile
    error — declare a plain behaviour with `@behaviour` as usual.
  * **Optional callbacks** are enforced only if your module actually defines
    them.
  * **Matching is by `{name, arity}` only**, independent of whether you wrote
    `@impl true`.
  * **`use Bond, behaviours: […]` is the only entry point** — there is no
    `use TheBehaviour` shortcut in v1.

## Protocols

### At a glance

A protocol is a promise about a *family* of implementations. `Bond.Protocol`
lets you declare `@pre`/`@post` on a `defprotocol`'s functions and have them
enforced across **every** implementation — without the implementations knowing
anything about Bond:

```elixir
defprotocol Sized do
  use Bond.Protocol

  @post non_negative: result >= 0
  @spec size(t) :: non_neg_integer()
  def size(data)
end

# Implementations stay completely ordinary — no `use Bond`, no opt-in:
defimpl Sized, for: BoundedStack do
  def size(%BoundedStack{items: items}), do: length(items)
end

defimpl Sized, for: List do
  def size(list), do: length(list)
end
```

Every call through `Sized.size/1` now checks `result >= 0`, whichever
implementation runs. A violation reads:

```
** (Bond.PostconditionError) postcondition (from protocol Sized, impl Sized.List) failed in Sized.size/1
```

### Declaring contracts

A `@pre`/`@post` precedes the `def` it attaches to, exactly as it does in
`use Bond`. Contract expressions reference the protocol function's declared
argument names and, in a `@post`, `result`:

```elixir
defprotocol Account do
  use Bond.Protocol

  @pre sufficient: amount <= balance(data)
  @post non_negative: result >= 0
  def withdraw(data, amount)
end
```

Name your protocol arguments (`def size(data)`, not `def size(t)`) — a contract
that references an undeclared name is a compile error reported against the
protocol.

### How it works — dispatch-layer wrapping (Option B)

`defprotocol` generates a *dispatch* function: `Sized.size(data)` calls
`Sized.impl_for!(data).size(data)`. `Bond.Protocol` wraps that one dispatch
function, once, in the protocol module — it marks the function `defoverridable`
and redefines it to evaluate the precondition, call `super/…` (the original
dispatch), then evaluate the postcondition.

Because the wrap is on dispatch, the contract:

  * applies uniformly to **every** implementation, including ones written later
    or by third parties — they need zero Bond awareness;
  * needs no positional rebinding — the wrapper's parameter *is* the declared
    argument name;
  * **survives protocol consolidation** (the consolidated build preserves the
    wrapper).

### Diagnostics — which implementation failed?

The wrap is central, but a failure still names the implementation the call
resolved to: the error carries `:source_protocol` (the protocol) and `:impl`
(the resolved implementation module), both in the message and in the
`[:bond, :assertion, :failure]` telemetry metadata. The implementation is
resolved only on the failure path, so a passing contract pays nothing for it.

## Semantics shared by both flavours

### What a contract may reference

A contract may reference only the abstraction's named arguments (a callback's
parameters, or a protocol function's), plus `result` in a `@post`. Referencing
any other name is a compile error, reported against the abstraction where the
contract is declared rather than against each implementation that inherits it.
Both the bare form (`@post result >= 0`) and the labelled keyword form
(`@post non_negative: result >= 0`) are supported, matching `use Bond`.

The reference rule applies to *free* names — names that must resolve to
something outside the expression. A name **bound** by a `<~` match pattern is
not free: the match introduces it, so it need not be an argument. This lets a
`@post` destructure the result and constrain its parts in one expression:

```elixir
@post ok_string: ({:ok, path} when is_binary(path)) <~ result
```

Here `path` is bound by the pattern on the left of `<~`, and the `when` guard
references that local binding — neither is an argument, and both are fine. Only
the pattern's own bindings are exempt: a `when` guard may still reference an
outer name, and that reference *is* validated. In
`({:ok, v} when v > limit) <~ result`, `v` is pattern-bound but `limit` must be
a declared argument (or `result`), or it is a compile error.

### Immutable inheritance (v1)

Inherited contracts are **immutable**. An implementation may not weaken,
strengthen, refine, or add to them. For a behaviour, attaching `@pre`/`@post`
to an implementation function whose `{name, arity}` matches an inherited
contract is a compile error:

```elixir
defmodule BankAccount do
  use Bond, behaviours: [Ledger]

  @impl true
  @pre amount > 100   # ** (CompileError) ... may not declare its own @pre/@post ...
  def withdraw(balance, amount), do: balance - amount
end
```

Protocol implementations enforce the protocol's contracts verbatim for the same
reason — there is no per-implementation `@pre`/`@post` to attach.

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

For a behaviour, the sanctioned escape hatch for an implementation-specific
assertion is `check/1` in the function body — it is independent of the contract
chain:

```elixir
@impl true
def withdraw(balance, amount) do
  check sufficient_funds: amount <= balance
  balance - amount
end
```

Helper functions and public functions *outside* the abstraction keep ordinary
`@pre`/`@post`, and struct `@invariant`s compose untouched.

### Runtime configuration

Inherited contracts honour the same runtime controls as ordinary contracts:
`config :bond, …` and the `Bond.Config` runtime API toggle them, and they obey
the contract-checking chain (`preconditions ≤ postconditions ≤ invariants`).

## Scope and non-goals (v1)

v1 is the immutable model only, for both flavours. The following are
deliberately out of scope:

  * **Refinement.** Eiffel-style contravariant/covariant *refinement*
    (`@pre_else` / `@post_then`) is a tracked follow-up; the immutable model is
    forward-compatible with it.
  * **Protocols — only dispatch is checked.** A direct call to a concrete
    implementation module (`Sized.List.size/1`) bypasses dispatch and is
    therefore *not* checked. Call through the protocol (`Sized.size/1`).
  * **Protocols — `old/1` is not supported** in a protocol `@post`; the
    dispatch wrapper does not snapshot entry state. Using it is a compile
    error.
  * **Protocols — compile-time `:purge`** of contracts is not supported; use
    runtime configuration to disable them.
