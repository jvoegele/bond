# Contract Inheritance for Protocols

A protocol is a promise about a *family* of implementations. `Bond.Protocol` lets you declare
`@pre`/`@post` contracts on a `defprotocol`'s functions and have them enforced across **every**
implementation — present and future — without the implementations knowing anything about Bond.

This is the protocol analogue of [Contract Inheritance for
Behaviours](contract-inheritance.md): Design by Contract meeting the Liskov Substitution
Principle, where the contract rides on the protocol's dispatch rather than on each callback.

## At a glance

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

Every call through `Sized.size/1` now checks `result >= 0`, whichever implementation runs. A
violation reads:

```
** (Bond.PostconditionError) postcondition (from protocol Sized, impl Sized.List) failed in Sized.size/1
```

## Declaring contracts

A `@pre`/`@post` precedes the `def` it attaches to, exactly as a contract precedes the `def` it
attaches to in `use Bond`. Contract expressions reference the protocol function's **declared
argument names** and, in a `@post`, `result` (the return value):

```elixir
defprotocol Account do
  use Bond.Protocol

  @pre sufficient: amount <= balance(data)
  @post non_negative: result >= 0
  def withdraw(data, amount)
end
```

Both the bare form (`@post result >= 0`) and the labelled keyword form
(`@post non_negative: result >= 0`) are supported, matching `use Bond`.

A contract may reference only the function's named arguments (plus `result` in a `@post`).
Referencing any other name is a compile error reported against the protocol, where the contract
is declared — name your protocol arguments (`def size(data)`, not `def size(t)`).

## How it works — dispatch-layer wrapping (Option B)

`defprotocol` generates a *dispatch* function: `Sized.size(data)` calls
`Sized.impl_for!(data).size(data)`. `Bond.Protocol` wraps that one dispatch function, once, in
the protocol module — it marks the function `defoverridable` and redefines it to evaluate the
precondition, call `super/…` (the original dispatch), then evaluate the postcondition.

Because the wrap is on dispatch, the contract:

  * applies uniformly to **every** implementation, including ones written later or by third
    parties — they need zero Bond awareness;
  * needs no positional rebinding — the wrapper's parameter *is* the declared argument name;
  * **survives protocol consolidation** (the consolidated build preserves the wrapper).

## Diagnostics — which implementation failed?

The wrap is central, but a failure still names the implementation the call resolved to: the
error carries `:source_protocol` (the protocol) and `:impl` (the resolved implementation
module), both in the message and in the `[:bond, :assertion, :failure]` telemetry metadata. The
implementation is resolved only on the failure path, so a passing contract pays nothing for it.

## Runtime configuration

Protocol contracts honour the same runtime controls as ordinary contracts: `config :bond, …`
and the `Bond.Config` runtime API toggle them, and they obey the contract-checking chain
(`preconditions ≤ postconditions ≤ invariants`).

## Scope and non-goals (v1)

  * **Immutable inheritance.** Implementations enforce the protocol's contracts verbatim and
    cannot weaken, strengthen, or refine them. (Per-implementation refinement is reserved for a
    future Eiffel-style refinement feature.)
  * **Only dispatch is checked.** A direct call to a concrete implementation module
    (`Sized.List.size/1`) bypasses dispatch and is therefore *not* checked. Call through the
    protocol (`Sized.size/1`).
  * **`old/1` is not supported** in a protocol `@post` — the dispatch wrapper does not snapshot
    entry state. Using it is a compile error.
  * **Compile-time `:purge`** of protocol contracts is not supported; use runtime configuration
    to disable them.
