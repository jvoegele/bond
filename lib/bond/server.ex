defmodule Bond.Server do
  @moduledoc """
  Design by Contract for `GenServer` process state.

  Bond's struct `@invariant` constrains every *value* of a type, but the state most worth
  constraining in Elixir is the state that changes over time inside a process. `Bond.Server`
  brings contracts to that state: declare module-wide properties of a server's state and Bond
  checks them automatically around the server's state-transition callbacks.

      defmodule Counter do
        use GenServer
        use Bond.Server

        @state_invariant non_negative: state.count >= 0

        @impl true
        def init(n), do: {:ok, %{count: n}}

        @impl true
        def handle_call(:inc, _from, state), do: {:reply, :ok, %{state | count: state.count + 1}}
      end

  A `@state_invariant` is checked after every state-transition callback returns a new state —
  `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `handle_continue/2`, and
  `code_change/3` — and a violation raises `Bond.InvariantError` (with `:kind`
  `:state_invariant`). Unlike a struct
  `@invariant`, this fires even when a callback mutates state inline (the common case), because
  Bond wraps the callbacks themselves rather than relying on the state flowing through a
  contracted pure function.

  > #### Usage order {: .info}
  >
  > `use GenServer` must come **before** `use Bond.Server`. Bond.Server detects the callbacks
  > you define via the `@on_definition` compiler hook, which only sees definitions made after
  > it is installed; `use GenServer` provides default callback implementations during its own
  > expansion, so putting it first keeps those defaults out of Bond.Server's view.

  ## Transition invariants

  A `@transition_invariant` relates the *prior* state to the *next* state across a transition,
  via the implicit `old_state` and `new_state` bindings:

      @transition_invariant monotonic: new_state.count >= old_state.count

  It is checked across every transition callback — `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, `handle_continue/2` — and a violation raises `Bond.InvariantError` (with
  `:kind` `:transition_invariant`). A transition invariant is what the Design by Contract
  literature calls a *history constraint* (Liskov & Wing).
  `init/1` and `code_change/3` are treated as re-creations: they establish a new state (checked by
  `@state_invariant`) but have no comparable prior state, so transition invariants do not apply to
  them.

  Like Bond's other contracts, `@state_invariant` and `@transition_invariant` checks honour the
  `:invariants` configuration and runtime gate: both share the `:invariants` kind, so they observe
  the precondition ≤ postcondition ≤ invariant chain, are compiled out entirely under
  `invariants: :purge`, and can be toggled at runtime with `Bond.Config.enable/1`/`disable/1`. See
  `Bond` and `Bond.Config`.
  """

  defmacro __using__(opts) do
    quote do
      # Bond.Server builds on the full Bond machinery: `use Bond` installs the `@`-override (so
      # `@state_invariant`/`@transition_invariant` are captured), the compile-state FSM, and the
      # runtime contract gate.
      use Bond, unquote(opts)

      # Marks this module as a Bond.Server so `Bond.Compiler.__before_compile__` knows the captured
      # invariants have a consumer; without it, they would be an orphaned contract and warned about.
      Module.put_attribute(__MODULE__, :__bond_server__, true)

      # The codegen — callback detection and the wrapper/check emission — lives in
      # `Bond.Compiler.Server` (the compiler half of Bond.Server, as `Bond.Compiler` is to `Bond`).
      Module.register_attribute(__MODULE__, :bond_server_callbacks, accumulate: true)
      @on_definition Bond.Compiler.Server
      @before_compile Bond.Compiler.Server
    end
  end
end
