defmodule Bond.Server do
  @moduledoc """
  Design-by-Contract for `GenServer` process state.

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
  `code_change/3` — and a violation raises `Bond.StateInvariantError`. Unlike a struct
  `@invariant`, this fires even when a callback mutates state inline (the common case), because
  Bond wraps the callbacks themselves rather than relying on the state flowing through a
  contracted pure function.

  > #### Usage order {: .info}
  >
  > `use GenServer` must come **before** `use Bond.Server`. Bond.Server detects the callbacks
  > you define via the `@on_definition` compiler hook, which only sees definitions made after
  > it is installed; `use GenServer` provides default callback implementations during its own
  > expansion, so putting it first keeps those defaults out of Bond.Server's view.

  Like Bond's other contracts, `@state_invariant` checks honour the `:invariants` configuration
  and runtime gate: they are compiled out entirely under `invariants: :purge`, and can be toggled
  at runtime with `Bond.Config.enable/1`/`disable/1` (state invariants share the `:invariants`
  kind). See `Bond` and `Bond.Config`.

  Transition invariants (`@transition_invariant`, relating the prior and next state across a
  transition) are a separate, forthcoming part of issue #34.
  """

  # The GenServer state-transition callbacks Bond.Server reasons about. Each carries (or, for
  # init/1 and code_change/3, establishes) the server's state, so each is a point at which a
  # state invariant can be checked. `terminate/2` is excluded — it returns no new state.
  @genserver_callbacks [
    init: 1,
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    handle_continue: 2,
    code_change: 3
  ]

  @doc false
  def __genserver_callbacks__, do: @genserver_callbacks

  defmacro __using__(opts) do
    quote do
      # Bond.Server builds on the full Bond machinery: `use Bond` installs the `@`-override (so
      # `@state_invariant` is captured), the compile-state FSM, and the runtime contract gate.
      use Bond, unquote(opts)

      # Marks this module as a Bond.Server so `Bond.Compiler.__before_compile__` knows the captured
      # `@state_invariant`s have a consumer; without it, captured state invariants are an orphaned
      # contract and warned about.
      Module.put_attribute(__MODULE__, :__bond_server__, true)

      Module.register_attribute(__MODULE__, :bond_server_callbacks, accumulate: true)
      @on_definition Bond.Server
      @before_compile Bond.Server
    end
  end

  @doc false
  def __on_definition__(env, kind, fun, params, _guards, body) when kind in [:def, :defp] do
    fa = {fun, length(params)}

    # Record the GenServer callbacks the user actually defines. We deliberately do NOT gate on
    # `Module.overridable?/2`: a user's handle_call/handle_cast/handle_info fires `@on_definition`
    # while still marked overridable, because it overrides `use GenServer`'s pre-provided default
    # (Bond's general external-override heuristic in `Bond.Compiler` would wrongly drop it). The
    # GenServer defaults themselves never reach this hook — they are defined during `use
    # GenServer`, before `use Bond.Server` installs the hook — so every callback event we see
    # here is a genuine user clause. (See `spikes/server_defoverridable/`.)
    if body != nil and fa in @genserver_callbacks do
      Module.put_attribute(env.module, :bond_server_callbacks, fa)
    end

    :ok
  end

  def __on_definition__(_env, _kind, _fun, _params, _guards, _body), do: :ok

  @doc false
  defmacro __before_compile__(env) do
    callbacks =
      env.module
      |> Module.get_attribute(:bond_server_callbacks)
      |> Enum.uniq()
      # Keep a stable, declaration-independent order for reflection and codegen.
      |> then(fn defined -> Enum.filter(@genserver_callbacks, &(&1 in defined)) end)

    # State invariants are captured into `:bond_state_invariants` by
    # `Bond.Compiler.register_state_invariant/4` (via the `@state_invariant` override), newest-last
    # = declaration order. Expose the `{label, code}` pairs for reflection/testing; the full
    # assertions drive the check codegen below.
    state_invariants = Module.get_attribute(env.module, :bond_state_invariants) || []
    reflection = Enum.map(state_invariants, fn assertion -> {assertion.label, assertion.code} end)

    # State invariants are gated under the `:invariants` kind (zero new Bond.Config surface). The
    # resolved per-module config lives in `@__bond_contract_config__` (set by `use Bond`). `:purge`
    # compiles the checks out entirely — no check defp, no wrappers; `false`/`true` still emit the
    # wrapper with a runtime gate, so `Bond.Config.enable/disable(:invariants)` can flip it.
    config = Module.get_attribute(env.module, :__bond_contract_config__) || %{}
    modes = %{invariants: Map.get(config, :invariants, true), chain: chain(config)}

    runtime_ast =
      if modes.invariants == :purge or state_invariants == [] do
        []
      else
        state_invariant_check_ast(state_invariants) ++
          callback_wrappers_ast(callbacks, modes, env)
      end

    quote do
      @doc false
      def __bond_server_callbacks__, do: unquote(Macro.escape(callbacks))

      @doc false
      def __bond_state_invariants__, do: unquote(Macro.escape(reflection))

      unquote_splicing(runtime_ast)
    end
  end

  # The pre/post modes that gate the `:invariants` kind in `Bond.Runtime.Eval.should_evaluate?/3`
  # (the pre <= post <= invariants chain), mirroring struct `@invariant`s.
  defp chain(config) do
    %{
      preconditions: Map.get(config, :preconditions, true),
      postconditions: Map.get(config, :postconditions, true)
    }
  end

  # Wraps each user-defined GenServer callback with `defoverridable` + a wrapper that calls
  # `super`, extracts the new state from the return, and runs the state-invariant check against it,
  # gated under `:invariants`. `super` reaches the user's callback (the wrapping mechanism Bond uses
  # for every function; validated for GenServer callbacks in `spikes/server_defoverridable/`). In
  # Slice 1 every state-transition callback is wrapped identically — including `init/1` and
  # `code_change/3`, which establish a new state on which the invariant must also hold.
  defp callback_wrappers_ast(callbacks, modes, env) do
    chain = Macro.escape(modes.chain)
    mode = modes.invariants

    for {name, arity} <- callbacks do
      args = Macro.generate_arguments(arity, env.module)

      quote do
        defoverridable [{unquote(name), unquote(arity)}]

        @impl true
        def unquote(name)(unquote_splicing(args)) do
          result = super(unquote_splicing(args))

          if Bond.Runtime.Eval.should_evaluate?(:invariants, unquote(mode), unquote(chain)) do
            case Bond.Server.Runtime.extract_state(unquote(name), result) do
              {:state, bond_new_state} ->
                Bond.Runtime.Eval.evaluate_state_invariants(
                  fn -> __bond_state_invariant_check__(bond_new_state) end,
                  unquote(Macro.escape({name, arity}))
                )

              :no_state ->
                :ok
            end
          end

          result
        end
      end
    end
  end

  # Builds the shared `__bond_state_invariant_check__(state)` that evaluates every
  # `@state_invariant` against `state`, reusing `Bond.Runtime.Eval.check_assertion/3` exactly as
  # struct `@invariant`s do. Returns `[]` (no defp emitted) when the module declares none.
  #
  # The assertion-failure `:function` is NOT baked in here — it is added on the failure path by
  # `Bond.Runtime.Eval.evaluate_state_invariants/2` at the call site, because these module-level
  # invariants are shared across every callback. So the passing path allocates nothing beyond the
  # boolean checks, and the defp takes only `state` (keeping the failure binding to `[state: ...]`).
  # Only called with a non-empty list (the empty/`:purge` cases are short-circuited in
  # `__before_compile__`).
  defp state_invariant_check_ast(state_invariants) do
    # The unhygienic `state` var the normalized assertion expressions resolve to (see
    # `Bond.Compiler.register_state_invariant/4`, which strips the hygiene context off `state`).
    state_var = Macro.var(:state, nil)

    checks =
      for assertion <- state_invariants do
        env = assertion.definition_env

        assertion_info = %{
          assertion_id: assertion.id,
          kind: :state_invariant,
          label: assertion.label,
          expression: assertion.code,
          file: env.file,
          line: env.line,
          module: env.module
        }

        quote do
          Bond.Runtime.Eval.check_assertion(
            unquote(assertion.expression),
            unquote(Macro.escape(assertion_info)),
            fn -> binding() end
          )
        end
      end

    [
      quote do
        @doc false
        def __bond_state_invariant_check__(unquote(state_var)) do
          import Bond.Predicates

          unquote_splicing(checks)
          :ok
        end
      end
    ]
  end
end
