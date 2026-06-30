defmodule Bond.Compiler.Server do
  @moduledoc internal: true
  @moduledoc """
  Compile-time code generation for `Bond.Server` (#34).

  Installed as the `@on_definition` and `@before_compile` handler by `use Bond.Server`, this is
  the codegen half of `Bond.Server` — the same relationship `Bond.Compiler` has to `Bond`. It:

    * records, via `@on_definition`, the `GenServer` state-transition callbacks the module
      actually defines (see `__on_definition__/6` for why `Module.overridable?/2` must not gate
      this);
    * at `@before_compile`, emits a `defoverridable` plus a wrapper around each such callback that
      calls `super`, extracts the new state with `Bond.Runtime.Server.extract_state/2`, and runs
      the module's `@state_invariant` / `@transition_invariant` checks against it — gated under the
      `:invariants` kind, and compiled out entirely under `invariants: :purge`.

  The `@state_invariant` / `@transition_invariant` declarations themselves are captured upstream by
  `Bond.Compiler.register_state_invariant/4` / `register_transition_invariant/4`.
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

  alias Bond.Compiler.Assertion

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
    state_invariants = Module.get_attribute(env.module, :bond_state_invariants) || []
    transition_invariants = Module.get_attribute(env.module, :bond_transition_invariants) || []

    # State and transition invariants are gated under the `:invariants` kind (zero new Bond.Config
    # surface). The resolved per-module config lives in `@__bond_contract_config__` (set by `use
    # Bond`). `:purge` compiles the checks out entirely — no check defp, no wrappers; `false`/`true`
    # still emit the wrapper with a runtime gate, so `Bond.Config.enable/disable(:invariants)` flips
    # it.
    config = Module.get_attribute(env.module, :__bond_contract_config__) || %{}
    modes = %{invariants: Map.get(config, :invariants, true), chain: chain(config)}

    runtime_ast =
      if modes.invariants == :purge do
        []
      else
        invariant_check_ast(
          :__bond_state_invariant_check__,
          [:state],
          state_invariants,
          :state_invariant
        ) ++
          invariant_check_ast(
            :__bond_transition_invariant_check__,
            [:old_state, :new_state],
            transition_invariants,
            :transition_invariant
          ) ++
          callback_wrappers_ast(callbacks, state_invariants, transition_invariants, modes, env)
      end

    quote do
      @doc false
      def __bond_server_callbacks__, do: unquote(Macro.escape(callbacks))

      @doc false
      def __bond_state_invariants__, do: unquote(Macro.escape(reflection(state_invariants)))

      @doc false
      def __bond_transition_invariants__,
        do: unquote(Macro.escape(reflection(transition_invariants)))

      unquote_splicing(runtime_ast)
    end
  end

  # The captured `{label, code}` pairs exposed by the reflection functions above.
  defp reflection(assertions), do: Enum.map(assertions, &{&1.label, &1.code})

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
          server_invariant_call(:__bond_state_invariant_check__, [new_state], fa_ast)
        end

      transition_call =
        if emit_transition? do
          server_invariant_call(
            :__bond_transition_invariant_check__,
            [List.last(args), new_state],
            fa_ast
          )
        end

      checks = Enum.reject([state_call, transition_call], &is_nil/1)

      [
        quote do
          defoverridable [{unquote(name), unquote(arity)}]

          @impl true
          def unquote(name)(unquote_splicing(args)) do
            result = super(unquote_splicing(args))

            if Bond.Runtime.Eval.should_evaluate?(:invariants, unquote(mode), unquote(chain)) do
              case Bond.Runtime.Server.extract_state(unquote(name), result) do
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

  # A gated invariant-check call: run the lifted `check_fn` over `check_args`, attributing any
  # failure to `fa_ast` (added on the failure path by `evaluate_server_invariants/2`).
  defp server_invariant_call(check_fn, check_args, fa_ast) do
    quote do
      Bond.Runtime.Eval.evaluate_server_invariants(
        fn -> unquote(check_fn)(unquote_splicing(check_args)) end,
        unquote(fa_ast)
      )
    end
  end

  # Builds the lifted `def <fn_name>(<vars>)` that evaluates every invariant of `kind` against the
  # bound state var(s), reusing `Bond.Runtime.Eval.check_assertion/3` exactly as struct
  # `@invariant`s do (`:state` for state invariants; `:old_state`/`:new_state` for transition
  # invariants). Returns `[]` (no defp emitted) when the module declares none of that kind.
  #
  # The assertion-failure `:function` is NOT baked in here — it is added on the failure path by
  # `Bond.Runtime.Eval.evaluate_server_invariants/2` at the call site, because these module-level
  # invariants are shared across every callback. So the passing path allocates nothing beyond the
  # boolean checks, and the failure binding is just the state var(s).
  defp invariant_check_ast(_fn_name, _var_names, [], _kind), do: []

  defp invariant_check_ast(fn_name, var_names, assertions, kind) do
    # Unhygienic vars the normalized assertion expressions resolve to (see
    # `Bond.Compiler.register_{state,transition}_invariant/4`, which strip the hygiene context).
    vars = Enum.map(var_names, &Macro.var(&1, nil))
    checks = assertion_check_calls(assertions, kind)

    [
      quote do
        @doc false
        def unquote(fn_name)(unquote_splicing(vars)) do
          import Bond.Predicates

          unquote_splicing(checks)
          :ok
        end
      end
    ]
  end

  # The per-assertion `check_assertion/3` calls shared by the check-defp builder, with
  # `where`/`whenever` binding groups (#47) wrapped in a `case` via `Assertion.grouped_eval/3`
  # (the same grouping `@pre`/`@post`/`@invariant` use). `:function` is omitted (added on the
  # failure path by the `evaluate_server_invariants/2` catcher); the binding is deferred via a
  # `fn -> binding() end` thunk so it is built only on failure.
  defp assertion_check_calls(assertions, kind) do
    Assertion.grouped_eval(
      assertions,
      &server_check_call(&1, kind),
      &server_shape_mismatch(&1, &2, kind)
    )
  end

  defp server_check_call(assertion, kind) do
    quote do
      Bond.Runtime.Eval.check_assertion(
        unquote(assertion.expression),
        unquote(Macro.escape(server_assertion_info(assertion, kind, assertion.code))),
        fn -> binding() end
      )
    end
  end

  # The `:assert` (`where`) non-match branch for a server invariant: a laundered `false` through
  # `check_assertion/3` (so the `:shape` violation flows through `evaluate_server_invariants/2`
  # identically), rendering the violated `pattern = source`.
  defp server_shape_mismatch(binding, anchor, kind) do
    info = server_assertion_info(anchor, kind, Assertion.shape_code(binding), :shape)

    quote do
      Bond.Runtime.Eval.check_assertion(
        Bond.Predicates.__opaque__(false),
        unquote(Macro.escape(info)),
        fn -> binding() end
      )
    end
  end

  defp server_assertion_info(assertion, kind, expression, label \\ nil) do
    env = assertion.definition_env

    %{
      assertion_id: assertion.id,
      kind: kind,
      label: label || assertion.label,
      expression: expression,
      file: env.file,
      line: env.line,
      module: env.module
    }
  end
end
