# Invariants

`@pre` and `@post` constrain a single call. An `@invariant` constrains a *type* —
every value of a struct produced by or passed into its own module's public API.

Bond has two flavours, and this guide is the reference for both: **struct
invariants** (`@invariant`), and the **process-state invariants** a
`Bond.Server` adds (`@state_invariant` and `@transition_invariant`, covered
under [Stateful contracts for processes](#stateful-contracts-for-processes)).

For *why* a `GenServer` is the right home for stateful contracts — and why an
`Agent` is not — see
[Contracts in a Concurrent World](contracts-and-concurrency.md).

## `@invariant` for struct modules

`@invariant` declarations specify properties that hold for every value of
a struct, checked automatically on the way *into* and *out of* every
public function in the struct's defining module.

Where `@pre`/`@post` constrain a single function call, `@invariant`
constrains the struct itself — every instance produced by the module's
public API satisfies the invariant, every instance entering its public
API is expected to.

```elixir
defmodule BoundedStack do
  use Bond

  defstruct items: [], capacity: 0

  @invariant non_negative_capacity: subject.capacity >= 0,
             size_within_capacity: length(subject.items) <= subject.capacity

  def new(capacity) when is_integer(capacity) and capacity >= 0 do
    %__MODULE__{items: [], capacity: capacity}
  end

  def push(%__MODULE__{} = stack, item) do
    %{stack | items: [item | stack.items]}
  end
end
```

> #### Give `defstruct` defaults that satisfy the invariant {: .tip}
>
> Note `defstruct items: [], capacity: 0` rather than `defstruct [:items, :capacity]`.
> Nothing stops a caller writing a bare `%BoundedStack{}`, and with `nil` defaults the
> first invariant to touch it evaluates `length(nil)` — which raises
> `Bond.AssertionEvaluationError`, because the assertion could not be evaluated at all
> (see [Writing sound assertions](writing-sound-assertions.md)).
>
> This is Meyer's base case made concrete. His correctness rule requires that a class's
> default field values satisfy the invariant when there is no explicit creation procedure
> (*Object-Oriented Software Construction*, 2nd edition, §11.9). Elixir always has that
> case, because `%Mod{}` is always available — so your `defstruct` defaults are part of
> the contract whether you meant them to be or not.

### The `subject` binding

Inside an `@invariant` expression, **`subject` refers to the struct
instance being checked**. Bond rebinds `subject` at every check site to
whichever struct parameter the function head exposes — you write the
invariant once against `subject` and Bond handles the rest, regardless of
what each function names its struct parameter.

### When invariants fire

Invariants check at the boundaries of public functions in the struct's
module — the places a struct value crosses between "internal" (possibly
transient) and "external" (must be valid). Bond auto-detects the struct
parameter in any of these head shapes:

| Function head shape | Detected? | Pre-check on entry |
|---|---|---|
| `def foo(%__MODULE__{} = name, ...)` | yes | yes, on the captured struct |
| `def foo(x, ...) when is_struct(x, __MODULE__)` | yes | yes, on `x` |
| `def foo(%__MODULE__{field: ...}, ...)` (destructure-only) | yes | yes, on the captured struct |
| `def foo({:wrapped, %__MODULE__{} = name})` (nested, bound) | yes | yes, on `name` |
| `def foo({:wrapped, %__MODULE__{field: ...}})` (nested, destructure-only) | no | skipped — nothing is bound to check |
| `def foo(x, ...)` (no pattern, no guard) | no | skipped silently |
| `defp ...` (any shape) | no | skipped — private functions exempt by Eiffel convention |

You may name the struct however you like, in every position above. `%MyApp.Cart{} = cart`,
`is_struct(cart, MyApp.Cart)`, and — if you use the `alias __MODULE__` idiom — the short
`%Cart{} = cart` are all detected exactly as the `__MODULE__` forms are. Bond resolves the
name against the module's own alias table, so it agrees with what Elixir itself resolves.

The corollary is that a name is only detected when it really does mean this module. A bare
`%Cart{}` inside `MyApp.Cart` with **no** alias in scope refers to `Elixir.Cart`, a
different module, and Bond treats it as one — as does Elixir.

A struct carried *inside* a tuple, map, or list is checked too, as long as the head binds
it to a name: `def handle({:wrapped, %__MODULE__{} = cart})` gets an entry check on
`cart`, and a head nesting several structs checks each, left to right. What is not checked
is a nested pattern that binds nothing —
`def handle({:wrapped, %__MODULE__{items: items}})` gives Bond no value to hand the
invariant. Add `= name` if you want the check:

```elixir
def handle({:wrapped, %__MODULE__{items: items} = cart}), do: ...
```

The post-check on exit matches both `%__MODULE__{}` and `{:ok,
%__MODULE__{}}` return shapes. Other shapes (`{:error, _}`, bare
integers, etc.) fall through with no check. If your function returns the
struct under a different wrapper, add an explicit `@post`.

Multiple struct parameters in the same head (e.g. `def
merge(%__MODULE__{} = a, %__MODULE__{} = b)`) are all checked in
left-to-right order; `subject` rebinds to each in turn.

> #### Why check on entry at all? {: .info}
>
> If every function that produces a struct checks it on the way out, entry checks look
> redundant — and in a language with immutable data they very nearly are. Eiffel needs
> them for a reason Elixir does not have: aliasing. Meyer calls it the *Indirect Invariant
> Effect* (§11.14) — object `a`'s invariant can be broken by an operation on object `b`
> that happens to hold a reference into `a`, so a state that was valid when a call
> returned may not be valid when the next call starts. Elixir values cannot change behind
> your back, so that failure mode is gone.
>
> The entry check earns its place here for a different reason: Elixir gives no module a
> monopoly on constructing its struct. `%BoundedStack{items: [1, 2, 3], capacity: 1}` is
> valid syntax for anyone, anywhere, and it never passes through `new/1`. The entry check
> is what notices. (Mutable process state brings the aliasing problem back, which is what
> [Contracts in a Concurrent World](contracts-and-concurrency.md) is about.)

### Violation behaviour

A violated invariant raises `Bond.InvariantError` with the same metadata
shape as `Bond.PreconditionError` / `Bond.PostconditionError`, and fires
the same telemetry event (`[:bond, :assertion, :failure]` with
`:kind => :invariant`). Test with
`Bond.Test.assert_invariant_violation/2`.

### Breaking the invariant on purpose, mid-operation

An invariant is not required to hold *during* an operation. Meyer is explicit that a
routine may work toward its postcondition, destroy the invariant along the way, and
restore it before returning — the invariant characterises the states in which an object
is observable from outside, not every instant of its life (§11.8).

Bond's version of "observable from outside" is the boundary of a **public** function. So
a helper that legitimately receives a transiently-invalid struct must be **private**:

```elixir
# ❌ raises Bond.InvariantError on entry to trim/1, even though push/2
#    would have restored the invariant before returning
def push(%__MODULE__{} = stack, item) do
  %{stack | items: [item | stack.items]} |> trim()
end

def trim(%__MODULE__{} = stack), do: %{stack | items: Enum.take(stack.items, stack.capacity)}
```

```elixir
# ✅ defp is exempt, so the intermediate state is nobody else's business
def push(%__MODULE__{} = stack, item) do
  %{stack | items: [item | stack.items]} |> trim()
end

defp trim(%__MODULE__{} = stack), do: %{stack | items: Enum.take(stack.items, stack.capacity)}
```

This is why private functions are exempt rather than merely unchecked: Eiffel draws the
same line ("a secret feature is not affected by the invariant"). If a helper needs to see
a half-built struct, that is a statement about who owns the intermediate state, and `defp`
is how you say it.

### What's not supported

Invariants are scoped to the **struct's own defining module**. External
modules that operate on the struct can't declare invariants for it —
this matches Eiffel's class-locality and keeps cross-module ownership
clean.

For a **`GenServer`**'s process state, `Bond.Server` adds `@state_invariant`
and `@transition_invariant` — see
[Stateful contracts for processes](#stateful-contracts-for-processes) below.
For **`Agent`** state and other state shared across processes there is no
separate feature: keep the state in a struct and declare invariants on that
struct's module, which the
[Contracts in a Concurrent World](contracts-and-concurrency.md) guide works
through.

## Stateful contracts for processes

A struct `@invariant` constrains every *value* of a type. `Bond.Server` constrains
the *state of a running `GenServer`*: `use Bond.Server` **after** `use GenServer`,
then declare module-wide invariants Bond checks around the server's callbacks.

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

- **`@state_invariant`** (binding `state`) is checked after every state-transition
  callback returns a new state — `init/1`, `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, `handle_continue/2`, `code_change/3`.
- **`@transition_invariant`** (bindings `old_state`, `new_state`) relates the prior
  state to the next across every transition — `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, `handle_continue/2`. `init/1` and `code_change/3` are re-creations
  and are exempt. (A transition invariant is what the Design by Contract literature
  calls a *history constraint*.)

Both raise `Bond.InvariantError` on violation — the same error as a struct `@invariant`,
distinguished by its `:kind` field (`:state_invariant` / `:transition_invariant`).
Unlike a struct `@invariant` — which only fires when the struct flows through a
function of its own module — these wrap the callbacks themselves, so they catch the
common case of a callback mutating state inline. Because the checks run inside the
serialized server process, even a temporal property like "the counter never
decreases" is race-free: the `:dec` cast above raises it across `handle_cast/2`.

`@state_invariant`/`@transition_invariant` share the `:invariants` configuration kind —
they honour the contract-checking chain, toggle with `Bond.Config.disable(:invariants)`,
and compile out under `invariants: :purge`. Declaring either outside a `Bond.Server`
module is a compile warning.

See `Bond.Server` for the module reference,
[Contracts in a Concurrent World](contracts-and-concurrency.md) for why the
serialized server process is what makes a temporal property like `monotonic`
soundly assertable at all, and
[Testing Contracts](testing-contracts.md#testing-bond-servers) for driving these
invariants from a property test.
