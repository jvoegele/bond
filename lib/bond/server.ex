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

  ## Transition invariants

  A `@transition_invariant` relates the *prior* state to the *next* state across a transition,
  via the implicit `old_state` and `new_state` bindings:

      @transition_invariant monotonic: new_state.count >= old_state.count

  It is checked across every transition callback — `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, `handle_continue/2` — and a violation raises `Bond.TransitionInvariantError`.
  `init/1` and `code_change/3` are treated as re-creations: they establish a new state (checked by
  `@state_invariant`) but have no comparable prior state, so transition invariants do not apply to
  them.

  Like Bond's other contracts, `@state_invariant` and `@transition_invariant` checks honour the
  `:invariants` configuration and runtime gate: they are compiled out entirely under
  `invariants: :purge`, and can be toggled at runtime with `Bond.Config.enable/1`/`disable/1`
  (both share the `:invariants` kind). See `Bond` and `Bond.Config`.
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

  # The callbacks that perform a genuine state *transition* — they receive a prior state and
  # return a next one — and so carry `@transition_invariant` checks. For all four, the incoming
  # state is the LAST argument. `init/1` and `code_change/3` are excluded: they establish a new
  # state (and get `@state_invariant` checks) but have no comparable prior state, so a transition
  # invariant would be meaningless or spurious across them.
  @transition_callbacks [handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2]

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

    # State and transition invariants are captured into `:bond_state_invariants` /
    # `:bond_transition_invariants` by `Bond.Compiler.register_{state,transition}_invariant/4` (via
    # the `@state_invariant` / `@transition_invariant` overrides), newest-last = declaration order.
    # Expose the `{label, code}` pairs for reflection/testing; the full assertions drive the check
    # codegen below.
    state_invariants = Module.get_attribute(env.module, :bond_state_invariants) || []
    transition_invariants = Module.get_attribute(env.module, :bond_transition_invariants) || []

    reflection = fn assertions ->
      Enum.map(assertions, fn assertion -> {assertion.label, assertion.code} end)
    end

    # State invariants are gated under the `:invariants` kind (zero new Bond.Config surface). The
    # resolved per-module config lives in `@__bond_contract_config__` (set by `use Bond`). `:purge`
    # compiles the checks out entirely — no check defp, no wrappers; `false`/`true` still emit the
    # wrapper with a runtime gate, so `Bond.Config.enable/disable(:invariants)` can flip it.
    config = Module.get_attribute(env.module, :__bond_contract_config__) || %{}
    modes = %{invariants: Map.get(config, :invariants, true), chain: chain(config)}

    runtime_ast =
      if modes.invariants == :purge do
        []
      else
        state_invariant_check_ast(state_invariants) ++
          transition_invariant_check_ast(transition_invariants) ++
          callback_wrappers_ast(callbacks, state_invariants, transition_invariants, modes, env)
      end

    quote do
      @doc false
      def __bond_server_callbacks__, do: unquote(Macro.escape(callbacks))

      @doc false
      def __bond_state_invariants__, do: unquote(Macro.escape(reflection.(state_invariants)))

      @doc false
      def __bond_transition_invariants__,
        do: unquote(Macro.escape(reflection.(transition_invariants)))

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
  # `super`, extracts the new state from the return, and runs the applicable invariant checks
  # against it, gated under `:invariants`. `super` reaches the user's callback (the wrapping
  # mechanism Bond uses for every function; validated for GenServer callbacks in
  # `spikes/server_defoverridable/`).
  #
  # A callback is wrapped only if it has at least one applicable check: every callback gets the
  # `@state_invariant` check (on the new state), and the four transition callbacks additionally get
  # the `@transition_invariant` check (relating the incoming state — the last argument — to the new
  # state). `init/1` and `code_change/3` get state checks only.
  defp callback_wrappers_ast(callbacks, state_invariants, transition_invariants, modes, env) do
    chain = Macro.escape(modes.chain)
    mode = modes.invariants
    has_state? = state_invariants != []
    has_transition? = transition_invariants != []

    Enum.flat_map(callbacks, fn {name, arity} = fa ->
      wrapper_ast(name, arity, fa, has_state?, has_transition?, mode, chain, env)
    end)
  end

  defp wrapper_ast(name, arity, fa, has_state?, has_transition?, mode, chain, env) do
    emit_transition? = has_transition? and fa in @transition_callbacks

    if not has_state? and not emit_transition? do
      []
    else
      args = Macro.generate_arguments(arity, env.module)

      # Share one var across the case pattern and the closures below (separate `quote` blocks would
      # otherwise each get their own hygienic `bond_new_state`).
      new_state = Macro.var(:bond_new_state, __MODULE__)
      fa_ast = Macro.escape(fa)

      state_call =
        if has_state? do
          quote do
            Bond.Runtime.Eval.evaluate_state_invariants(
              fn -> __bond_state_invariant_check__(unquote(new_state)) end,
              unquote(fa_ast)
            )
          end
        end

      transition_call =
        if emit_transition? do
          old_state = List.last(args)

          quote do
            Bond.Runtime.Eval.evaluate_transition_invariants(
              fn ->
                __bond_transition_invariant_check__(unquote(old_state), unquote(new_state))
              end,
              unquote(fa_ast)
            )
          end
        end

      checks = Enum.reject([state_call, transition_call], &is_nil/1)

      [
        quote do
          defoverridable [{unquote(name), unquote(arity)}]

          @impl true
          def unquote(name)(unquote_splicing(args)) do
            result = super(unquote_splicing(args))

            if Bond.Runtime.Eval.should_evaluate?(:invariants, unquote(mode), unquote(chain)) do
              case Bond.Server.Runtime.extract_state(unquote(name), result) do
                {:state, unquote(new_state)} ->
                  unquote_splicing(checks)
                  :ok

                :no_state ->
                  :ok
              end
            end

            result
          end
        end
      ]
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
  defp state_invariant_check_ast([]), do: []

  defp state_invariant_check_ast(state_invariants) do
    # The unhygienic `state` var the normalized assertion expressions resolve to (see
    # `Bond.Compiler.register_state_invariant/4`, which strips the hygiene context off `state`).
    state_var = Macro.var(:state, nil)
    checks = assertion_check_calls(state_invariants, :state_invariant)

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

  # The transition counterpart: `__bond_transition_invariant_check__(old_state, new_state)`,
  # evaluating every `@transition_invariant` against the two bound states. Same structure as
  # `state_invariant_check_ast/1`; the failure binding is `[old_state: ..., new_state: ...]`.
  defp transition_invariant_check_ast([]), do: []

  defp transition_invariant_check_ast(transition_invariants) do
    old_state_var = Macro.var(:old_state, nil)
    new_state_var = Macro.var(:new_state, nil)
    checks = assertion_check_calls(transition_invariants, :transition_invariant)

    [
      quote do
        @doc false
        def __bond_transition_invariant_check__(unquote(old_state_var), unquote(new_state_var)) do
          import Bond.Predicates

          unquote_splicing(checks)
          :ok
        end
      end
    ]
  end

  # The per-assertion `check_assertion/3` calls shared by both check-defp builders. `:function` is
  # omitted (added on the failure path by the `evaluate_*` catcher); the binding is deferred via a
  # `fn -> binding() end` thunk so it is built only on failure.
  defp assertion_check_calls(assertions, kind) do
    for assertion <- assertions do
      env = assertion.definition_env

      assertion_info = %{
        assertion_id: assertion.id,
        kind: kind,
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
  end
end
