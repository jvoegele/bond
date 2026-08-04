# Invariants

`@pre` and `@post` constrain a single call. An `@invariant` constrains a *type* —
every value of a struct produced by or passed into its own module's public API.

This guide covers struct invariants. For the state of a running process, see
[Contracts in a Concurrent World](contracts-and-concurrency.md), which covers
`Bond.Server`'s `@state_invariant` and `@transition_invariant`.

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

  defstruct [:items, :capacity]

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
| `def foo(x, ...)` (no pattern, no guard) | no | skipped silently |
| `defp ...` (any shape) | no | skipped — private functions exempt by Eiffel convention |

The post-check on exit matches both `%__MODULE__{}` and `{:ok,
%__MODULE__{}}` return shapes. Other shapes (`{:error, _}`, bare
integers, etc.) fall through with no check. If your function returns the
struct under a different wrapper, add an explicit `@post`.

Multiple struct parameters in the same head (e.g. `def
merge(%__MODULE__{} = a, %__MODULE__{} = b)`) are all checked in
left-to-right order; `subject` rebinds to each in turn.

### Violation behaviour

A violated invariant raises `Bond.InvariantError` with the same metadata
shape as `Bond.PreconditionError` / `Bond.PostconditionError`, and fires
the same telemetry event (`[:bond, :assertion, :failure]` with
`:kind => :invariant`). Test with
`Bond.Test.assert_invariant_violation/2`.

### What's not supported

Invariants are scoped to the **struct's own defining module**. External
modules that operate on the struct can't declare invariants for it —
this matches Eiffel's class-locality and keeps cross-module ownership
clean.

For a **`GenServer`**'s process state, `Bond.Server` adds `@state_invariant`
and `@transition_invariant` — see "Stateful contracts for processes" below. For
**`Agent`** state and other state shared across processes there is no separate
feature: keep the state in a struct and declare invariants on that struct's
module. The [Contracts in a Concurrent World](contracts-and-concurrency.md)
guide works through both.

## Stateful contracts for processes

A struct `@invariant` constrains every *value* of a type. `Bond.Server` constrains
the *state of a running `GenServer`*: do `use GenServer` and `use Bond.Server`
(in that order), then declare module-wide invariants Bond checks around the
server's callbacks.

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
module is a compile warning. See `Bond.Server` and the
[Contracts in a Concurrent World](contracts-and-concurrency.md) guide.
