defmodule Bond.Compiler do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts for a module at compile-time.

  Bond installs this module as the `@on_definition`, `@before_compile`, and `@after_compile`
  handler for any module that does `use Bond`. As the user's module is being compiled:

    * Every contract annotation — `@pre`, `@post`, `@invariant`, the `Bond.Server` state and
      transition invariants, and their `where`/`whenever` binding-group forms — is intercepted by
      `Bond` and forwarded here via `register_assertion/6` or `register_binding_group/7`, with
      `@doc` arriving through `register_doc/3`. The assertion's kind alone decides which implicit
      bindings are normalised and where it is stored; see the `@kinds` table below.
    * Every `def` and `defp` definition fires `__on_definition__/6`, which builds a
      `Bond.Compiler.FunctionDefinition` and feeds it to the per-module
      `Bond.Compiler.CompileStateFSM` process. The FSM groups clauses by `{module, fun, arity}`
      and attaches any pending preconditions/postconditions/docs to the resulting
      `Bond.Compiler.AnnotatedFunction`.
    * `__before_compile__/1` asks the FSM for every `AnnotatedFunction` that has a contract,
      folds in anything inherited or applied, and delegates to
      `AnnotatedFunction.apply_contract/2` to emit a `defoverridable` plus the override clauses
      that wrap the original function in pre/post evaluation.
    * `__after_compile__/2` stops the FSM process.

  Two neighbouring concerns live in their own modules rather than here:
  `Bond.Compiler.Config` resolves the per-module configuration this module's codegen reads
  (reached through `resolve_config/3`), and `Bond.Compiler.ContractMerge` folds behaviour-
  inherited and `@apply_contract` contracts into an `AnnotatedFunction`.
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Boundaries
  alias Bond.Compiler.Config
  alias Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.ContractDocs
  alias Bond.Compiler.ContractMerge
  alias Bond.Compiler.FunctionDefinition
  alias Bond.Compiler.NamedContracts

  # Functions Elixir auto-generates as a side effect of constructs like `defstruct` and
  # `defexception`. These show up via `@on_definition` and must not be tracked as user
  # contract candidates.
  @generated_functions ~w[__struct__ __exception__ __info__]a

  @doc false
  def init(module) do
    # Next link in the chain `Bond.__using__/1` starts: block until the FSM module is on disk
    # before calling into it. LOAD-BEARING — see the note there for why an `alias` plus a
    # qualified call establishes no ordering of its own. `start_link/1` in turn covers its own
    # callback module and the structs it builds.
    Code.ensure_compiled!(FSM)

    {:ok, _fsm_pid} = FSM.start_link(module)
    :ok
  end

  @doc """
  Reads the `__bond_contracts__/0` reflection of each behaviour and registers the combined
  contracts with `module`'s FSM, keyed by `{name, arity}`.

  Called from the `use Bond, behaviours: […]` expansion (the modules are already alias-resolved);
  `env` is the caller's `Macro.Env`, used to give any raised `CompileError` the source location
  of the `use Bond` call. Each behaviour must `use Bond.Behaviour` — a behaviour without
  `__bond_contracts__/0` raises, catching typos and accidental use of a plain behaviour. When two
  behaviours declare contracts for the same `{name, arity}`, the contracts must be structurally
  identical (conjoining is unsound; picking one is arbitrary), otherwise a `CompileError` is
  raised. Structural identity is compared on the contract's *source form* (kind/label/code text),
  not its meaning — `x <= 10` and `10 >= x` are treated as distinct.
  """
  @spec register_behaviours(module(), [module()], Macro.Env.t()) :: :ok
  def register_behaviours(_module, [], _env), do: :ok

  def register_behaviours(module, behaviours, %Macro.Env{} = env) when is_list(behaviours) do
    combined =
      behaviours
      |> Enum.map(fn behaviour ->
        Code.ensure_compiled!(behaviour)

        unless function_exported?(behaviour, :__bond_contracts__, 0) do
          raise CompileError,
            file: env.file,
            line: env.line,
            description: not_a_bond_behaviour_message(behaviour)
        end

        {behaviour, behaviour.__bond_contracts__()}
      end)
      |> combine_behaviour_contracts(env)

    FSM.inherited_contracts_def(FSM.server_ref(module), combined)
    :ok
  end

  # Fold each behaviour's contracts into a single `{name, arity} => entry` map. A clash on the
  # same key across behaviours is allowed only when the two entries are structurally identical.
  defp combine_behaviour_contracts(per_behaviour, env) do
    Enum.reduce(per_behaviour, %{}, fn {behaviour, contracts}, acc ->
      Enum.reduce(contracts, acc, fn {key, entry}, acc ->
        case Map.fetch(acc, key) do
          :error ->
            Map.put(acc, key, entry)

          {:ok, existing} ->
            if same_contract?(existing, entry) do
              acc
            else
              raise CompileError,
                file: env.file,
                line: env.line,
                description: conflicting_behaviours_message(key, behaviour, existing, entry)
            end
        end
      end)
    end)
  end

  # Two inherited contract entries are interchangeable when they agree on the canonical
  # argument names and on each assertion's kind/label/source-form, position by position.
  defp same_contract?(a, b) do
    a.arg_names == b.arg_names and
      assertion_shapes(a.preconditions) == assertion_shapes(b.preconditions) and
      assertion_shapes(a.postconditions) == assertion_shapes(b.postconditions)
  end

  defp assertion_shapes(assertions) do
    Enum.map(assertions, &{&1.kind, &1.label, &1.code})
  end

  defp not_a_bond_behaviour_message(behaviour) do
    "Bond: `#{inspect(behaviour)}` was given to `use Bond, behaviours: […]` but does not " <>
      "use `Bond.Behaviour` (no contracts to inherit). If it is a plain behaviour, declare it " <>
      "with `@behaviour #{inspect(behaviour)}` instead; if it should carry contracts, add " <>
      "`use Bond.Behaviour` to it."
  end

  defp conflicting_behaviours_message({fun, arity}, behaviour, _existing, _entry) do
    "Bond: conflicting inherited contracts for `#{fun}/#{arity}`. More than one behaviour in " <>
      "`behaviours: […]` (including `#{inspect(behaviour)}`) declares contracts for it, and " <>
      "they are not identical. Inherited contracts are immutable in v1, so Bond cannot combine " <>
      "them — make the declarations identical, or have only one behaviour constrain " <>
      "`#{fun}/#{arity}`."
  end

  @typedoc """
  Per-kind compilation mode. See `Bond.Compiler.Config`.
  """
  @type mode :: Config.mode()

  @typedoc """
  Resolved per-module contract configuration. See `Bond.Compiler.Config`.
  """
  @type contract_config :: Config.contract_config()

  @doc """
  Resolves the per-module contract configuration; see `Bond.Compiler.Config.resolve/3`.

  A `use Bond` expansion calls this rather than `Bond.Compiler.Config` directly, so that the only
  Bond module a user module takes a compile-time dependency on stays the one `bond.ex` already
  `require`s. See the note in `Bond.Compiler.Config`.
  """
  @spec resolve_config(module(), keyword(), keyword()) :: contract_config()
  defdelegate resolve_config(module, use_opts, global), to: Config, as: :resolve

  @doc false
  def __on_definition__(_env, kind, _fun, _params, _guards, _body)
      when kind in [:defmacro, :defmacrop] do
    # Contracts on macros are out of scope for Bond 1.0. The workaround is to
    # wrap the macro body in a regular function (def) annotated with contracts
    # and call that function from the macro.
    :ok
  end

  def __on_definition__(_env, _kind, fun, _params, _guards, _body)
      when fun in @generated_functions do
    :ok
  end

  # Bodyless function heads (`def foo(x)` with no `do` block) are used purely to attach
  # docs/specs/contracts to the clauses that follow. They don't produce executable code, so we
  # skip them — the contracts will be picked up by the first body-bearing clause.
  def __on_definition__(_env, kind, _fun, _params, _guards, nil) when kind in [:def, :defp] do
    :ok
  end

  def __on_definition__(env, kind, fun, params, guards, body) when kind in [:def, :defp] do
    # Read and consume the per-function `@bond_warn_skipped_invariants` override
    # so it scopes to this single def. The override is a tri-state: nil means
    # "inherit module/global config"; true/false explicitly enables/suppresses
    # the warning for this function regardless of module/global config.
    warn_override = Module.get_attribute(env.module, :bond_warn_skipped_invariants)

    if warn_override != nil,
      do: Module.delete_attribute(env.module, :bond_warn_skipped_invariants)

    # Same tri-state, for the Precondition Availability warning (#92).
    availability_override =
      Module.get_attribute(env.module, :bond_warn_unavailable_preconditions)

    if availability_override != nil,
      do: Module.delete_attribute(env.module, :bond_warn_unavailable_preconditions)

    # When another library makes a function `defoverridable` and then redefines it to wrap it
    # (Norm's `@contract`, anything built on the `decorator` library, etc.), the redefining
    # clause fires `@on_definition` while the function is still marked overridable. Genuine
    # user clauses are never overridable at this point. We tag the clause so the FSM can ignore
    # such generated wrappers when they re-appear for a function it has already tracked, rather
    # than tripping its "clauses must be grouped" / parameter-consistency checks.
    external_override? = Module.overridable?(env.module, {fun, length(params)})

    function_def =
      env
      |> FunctionDefinition.new(kind, fun, params, guards, body)
      |> FunctionDefinition.put_warn_skipped_invariants_override(warn_override)
      |> FunctionDefinition.put_warn_unavailable_preconditions_override(availability_override)
      |> FunctionDefinition.put_external_override(external_override?)

    FSM.function_def(fsm(env), function_def)
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    :ok = FSM.module_defined(fsm(env))
    warn_orphan_server_invariants(env)

    config =
      Module.get_attribute(env.module, :__bond_contract_config__) ||
        %{preconditions: true, postconditions: true, invariants: true}

    # Whether Bond owns `@` in this module, and therefore documentation. Read here — while the
    # module is still open — rather than deeper in the codegen, where `apply_contract/2` is also
    # reachable from unit tests holding an already-compiled module. See
    # `Bond.Compiler.ContractDocs.doc_clauses/5`.
    config =
      Map.put(
        config,
        :at_annotations,
        Module.get_attribute(env.module, :__bond_at_annotations__) != false
      )

    # The module's alias table, so invariant head detection can resolve a struct named
    # through an alias (`alias __MODULE__` then `%Cart{} = cart`) exactly as Elixir does,
    # rather than guessing from the name's trailing segments (#93). `__before_compile__`
    # runs with the module still open, so `env.aliases` is the table those heads were
    # compiled under. Only the `{alias, target}` pairs are carried — a whole `Macro.Env`
    # would not survive the escaping that some downstream paths do.
    config = Map.put(config, :aliases, env.aliases)

    # The module's private functions, for the Precondition Availability check (#92).
    # Read here because `Module.definitions_in/2` needs the module still open, and once
    # rather than per function.
    config =
      Map.put(config, :private_defs, MapSet.new(Module.definitions_in(env.module, :defp)))

    invariants = FSM.invariants(fsm(env))
    inherited = FSM.inherited_contracts(fsm(env))

    moduledoc_invariants_ast =
      build_moduledoc_invariants_ast(invariants, env.module, config[:invariants] || true)

    # Flatten this module's named contracts (expand `include` directives) once: used for both the
    # emitted reflection and apply-time local resolution.
    named = NamedContracts.flatten(env.module)

    # The merged-but-not-yet-codegen'd functions: inherited/applied contracts folded in and
    # invariants attached, filtered to those that actually carry a contract. Captured before
    # `apply_contract/2` turns each into override AST so boundary extraction can read their final
    # preconditions and argument names.
    annotated =
      fsm(env)
      |> FSM.annotated_functions()
      |> Enum.map(&ContractMerge.merge_inherited_contract(&1, inherited))
      |> Enum.map(&ContractMerge.merge_applied_contract(&1, inherited, named))
      |> Enum.map(&AnnotatedFunction.put_invariants(&1, invariants))
      |> Enum.filter(&AnnotatedFunction.override?/1)

    contract_overrides =
      annotated
      |> Enum.map(&AnnotatedFunction.apply_contract(&1, config))
      |> Enum.reject(&is_nil/1)

    named_contracts_ast = NamedContracts.reflection_ast(named)
    # Built from `annotated` *after* `apply_contract/2` has run, so any multi-clause
    # name-disagreement `CompileError` surfaces from contract compilation as before, not here.
    boundaries_ast = build_boundaries_reflection(annotated)
    precondition_shim_ast = build_precondition_shim(annotated, config)

    extras =
      Enum.reject(
        [named_contracts_ast, moduledoc_invariants_ast, boundaries_ast, precondition_shim_ast],
        &is_nil/1
      )

    extras ++ contract_overrides
  end

  # Emits the `__bond_precondition__/3` filter shim (#36): for each contracted function whose
  # precondition is actually compiled (`emits_preconditions?/2`), a clause that delegates to that
  # function's private lifted precondition defp through `Bond.Runtime.Eval.precondition_satisfied?/1`
  # — returning a boolean instead of raising, so `Bond.PropertyTest` can use `@pre` as a generator
  # *filter*. A trailing catch-all returns `true`: a function with no compiled precondition has
  # nothing to violate, so any input vacuously satisfies it. All clauses are emitted in one block so
  # they stay grouped (Elixir warns on scattered same-name/arity clauses). Modules with no compiled
  # preconditions emit nothing.
  defp build_precondition_shim(annotated, config) do
    clauses =
      annotated
      |> Enum.filter(&AnnotatedFunction.emits_preconditions?(&1, config))
      |> Enum.map(fn annotated_function ->
        fun = annotated_function.fun
        arity = annotated_function.arity
        pre_fn = AnnotatedFunction.precondition_fn_name(annotated_function)
        arg_vars = Macro.generate_arguments(arity, __MODULE__)

        quote do
          @doc false
          def __bond_precondition__(unquote(fun), unquote(arity), [unquote_splicing(arg_vars)]) do
            Bond.Runtime.Eval.precondition_satisfied?(fn ->
              unquote(pre_fn)(unquote_splicing(arg_vars))
            end)
          end
        end
      end)

    case clauses do
      [] ->
        nil

      _ ->
        catch_all =
          quote do
            @doc false
            def __bond_precondition__(_fun, _arity, _args), do: true
          end

        quote do
          (unquote_splicing(clauses ++ [catch_all]))
        end
    end
  end

  # Emits the `__bond_boundaries__/0` reflection: a map of `{fun, arity} => %{arg_index =>
  # [candidate values]}` extracted from each contracted function's precondition literals (#36).
  # `Bond.PropertyTest` reads this to probe a function exactly at its precondition boundaries.
  # The table holds only plain numbers, so it escapes directly — no env snapshotting needed.
  # Functions with no literal precondition boundary contribute nothing; a module with none emits
  # no reflection at all.
  defp build_boundaries_reflection(annotated) do
    table =
      annotated
      |> Enum.flat_map(fn annotated_function ->
        expressions = Enum.map(annotated_function.preconditions, & &1.expression)

        case Boundaries.extract(expressions, AnnotatedFunction.arg_names(annotated_function)) do
          empty when map_size(empty) == 0 ->
            []

          candidates ->
            [{{annotated_function.fun, annotated_function.arity}, candidates}]
        end
      end)
      |> Map.new()

    case table do
      empty when map_size(empty) == 0 ->
        nil

      entries ->
        quote do
          @doc false
          def __bond_boundaries__, do: unquote(Macro.escape(entries))
        end
    end
  end

  # Builds the AST that augments the user's `@moduledoc` with a generated
  # `## Invariants` section. Runs at the user module's compile-end, so
  # `Module.get_attribute(__MODULE__, :moduledoc)` has the user's authored
  # value (if any). Returns `nil` when there's nothing to add — no invariants
  # registered, or invariants are `:purge`d.
  defp build_moduledoc_invariants_ast(invariants, module, inv_mode) do
    case ContractDocs.moduledoc_invariants_section(invariants, module, inv_mode) do
      nil ->
        nil

      section ->
        quote do
          case Module.get_attribute(__MODULE__, :moduledoc) do
            {line, existing} when is_binary(existing) ->
              Module.put_attribute(
                __MODULE__,
                :moduledoc,
                {line, existing <> "\n\n" <> unquote(section)}
              )

            {_line, false} ->
              # User explicitly hid the moduledoc (`@moduledoc false`); respect that.
              :ok

            _ ->
              # No user moduledoc — synthesise one containing just the invariants section.
              Module.put_attribute(__MODULE__, :moduledoc, {1, unquote(section)})
          end
        end
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    FSM.stop(fsm(env))
  end

  # Every contract kind Bond registers, and the two axes on which they differ:
  #
  #   * `vars` — the implicit bindings whose hygiene context must be stripped, so that references
  #     in the assertion resolve to the unhygienic `Macro.var(name, nil)` the check codegen
  #     rebinds at the check site: `subject` for `@invariant`, `state` and
  #     `old_state`/`new_state` for the `Bond.Server` kinds. `@pre`/`@post` reference the
  #     function's own parameters, which are already in scope, so they normalise nothing.
  #
  #   * `sink` — where the assertion is stored. `{:fsm, event}` goes to the per-module
  #     `CompileStateFSM`, which associates per-function contracts with the definition that
  #     follows them and accumulates module-scoped `@invariant`s. `{:attr, name}` goes straight
  #     to a module attribute: the `Bond.Server` kinds are a flat module-level list with no
  #     per-function association and no multi-clause grouping — the FSM's whole reason for being
  #     — and are consumed by `Bond.Compiler.Server.__before_compile__/1` instead.
  @kinds %{
    precondition: %{vars: [], sink: {:fsm, :precondition_def}},
    postcondition: %{vars: [], sink: {:fsm, :postcondition_def}},
    invariant: %{vars: [:subject], sink: {:fsm, :invariant_def}},
    state_invariant: %{vars: [:state], sink: {:attr, :bond_state_invariants}},
    transition_invariant: %{
      vars: [:old_state, :new_state],
      sink: {:attr, :bond_transition_invariants}
    }
  }

  # `@pre`/`@post` are the surface spelling of the two per-function kinds.
  @kind_aliases %{pre: :precondition, post: :postcondition}

  @typedoc """
  A contract kind as `register_assertion/6` and `register_binding_group/7` accept it: the
  canonical kind, or the `:pre`/`:post` surface spelling of the first two.
  """
  @type register_kind ::
          :pre
          | :post
          | :precondition
          | :postcondition
          | :invariant
          | :state_invariant
          | :transition_invariant

  @doc false
  @spec register_assertion(
          register_kind(),
          Macro.t(),
          Bond.assertion_label() | nil,
          Macro.Env.t(),
          keyword()
        ) :: :ok
  def register_assertion(kind, expression, label, env, meta),
    do: register_assertion(kind, expression, label, env, meta, nil)

  @doc false
  # Registers one `@pre` / `@post` / `@invariant` / `@state_invariant` / `@transition_invariant`.
  # `refinement` tags a `@pre_weaken`/`@post_strengthen` (`nil` for a plain annotation) so that
  # `Bond.Compiler.ContractMerge.merge_inherited_contract/2` folds it into the inherited contract rather than rejecting it.
  @spec register_assertion(
          register_kind(),
          Macro.t(),
          Bond.assertion_label() | nil,
          Macro.Env.t(),
          keyword(),
          :pre_weaken | :post_strengthen | nil
        ) :: :ok
  def register_assertion(kind, expression, label, env, meta, refinement) do
    kind = canonical_kind(kind)
    store(kind, build_assertion(kind, expression, label, env, meta, refinement, nil), env)
  end

  @doc false
  # Registers the assertions scoped to one `where`/`whenever` destructuring form (#47). Each
  # `{label, expression}` becomes an ordinary `%Assertion{}` — so it keeps its own id, label,
  # telemetry, and Dialyzer-laundering — tagged with a shared `binding` group. `mode` is
  # `:assert` for `where` (`=`, a non-match is a violation) or `:conditional` for `whenever`
  # (`<-`, a non-match is vacuous); `pattern`/`source` are the destructuring pattern and the value
  # matched against it. The common `group_id` lets `Assertion.grouped_eval/3` recognise the run's
  # members and wrap them in a single `case` over `source`. Members are registered contiguously so
  # they stay adjacent in the sink's accumulation order.
  #
  # The binding *source* is normalised like a member expression (it is evaluated in the same
  # scope), while the pattern binds fresh names and is left exactly as written.
  @spec register_binding_group(
          register_kind(),
          :assert | :conditional,
          Macro.t(),
          Macro.t(),
          [{Bond.assertion_label() | nil, Macro.t()}],
          Macro.Env.t(),
          keyword()
        ) :: :ok
  def register_binding_group(kind, mode, pattern, source, labelled_assertions, env, meta)
      when mode in [:assert, :conditional] do
    kind = canonical_kind(kind)

    binding = %{
      mode: mode,
      pattern: pattern,
      source: normalize_var_context(source, implicit_vars(kind)),
      group_id: Assertion.generate_group_id()
    }

    for {label, expression} <- labelled_assertions do
      store(kind, build_assertion(kind, expression, label, env, meta, nil, binding), env)
    end

    :ok
  end

  defp canonical_kind(kind), do: Map.get(@kind_aliases, kind, kind)

  defp implicit_vars(kind), do: Map.fetch!(@kinds, kind).vars

  defp build_assertion(kind, expression, label, env, meta, refinement, binding) do
    Assertion.validate_expression!(expression, env)
    normalized = normalize_var_context(expression, implicit_vars(kind))

    kind
    |> Assertion.new(label, normalized, env, meta)
    |> then(&if refinement, do: Assertion.put_refinement(&1, refinement), else: &1)
    |> then(&if binding, do: Assertion.put_binding(&1, binding), else: &1)
  end

  # Stores one assertion in its kind's sink. FSM events are casts. Module attributes are appended
  # newest-last through get-append-put, because `Module.put_attribute/3` does not accumulate at
  # macro-expansion time.
  defp store(kind, assertion, env) do
    case Map.fetch!(@kinds, kind).sink do
      {:fsm, event} ->
        apply(FSM, event, [fsm(env), assertion])

      {:attr, attr} ->
        existing = Module.get_attribute(env.module, attr) || []
        Module.put_attribute(env.module, attr, existing ++ [assertion])
    end

    :ok
  end

  @doc false
  # Records an `@apply_contract` reference against the next function definition. The reference
  # normalises to `{:local, name}` or `{:remote, module, name}` (the module alias is expanded in
  # the caller's context now, establishing the compile-time dependency for the cross-module read
  # that resolution performs at `__before_compile__`). Arity is not known here; it comes from the
  # function the reference attaches to. v1 applies a single contract per function, so there is no
  # list form (applying multiple contracts is a documented non-goal).
  def register_apply_contract(expression, %Macro.Env{} = env, meta) do
    ref = NamedContracts.parse_ref(expression, env)
    line = Keyword.get(meta, :line, env.line)
    FSM.apply_contract_def(fsm(env), %{ref: ref, line: line, env: env})
    :ok
  end

  # Strip the hygiene context off every reference to an implicit binding (`subject`, `state`,
  # `old_state`/`new_state`) so they resolve to the unhygienic `Macro.var(name, nil)` the check
  # codegen rebinds at the check site, rather than to whatever the macro's expansion context held.
  # `@pre`/`@post` declare no implicit bindings, so they skip the walk entirely.
  defp normalize_var_context(expression, []), do: expression

  defp normalize_var_context(expression, var_names) do
    Macro.prewalk(expression, fn
      # A variable node is `{name, meta, context}` with both `name` and `context` atoms (a call
      # node's third element is its argument list). `var_names` is a runtime list, so the
      # membership test goes in the body, not the guard.
      {name, meta, ctx} when is_atom(name) and is_atom(ctx) ->
        if name in var_names, do: {name, meta, nil}, else: {name, meta, ctx}

      other ->
        other
    end)
  end

  # `@state_invariant` / `@transition_invariant` are only consumed by `Bond.Server` (which sets
  # `@__bond_server__`). In a plain `use Bond` module they are captured but never enforced — a
  # silently-ignored contract. Warn so the missing `use Bond.Server` is loud rather than
  # mysterious, pointing at the first such declaration.
  defp warn_orphan_server_invariants(env) do
    unless Module.get_attribute(env.module, :__bond_server__) == true do
      orphans =
        (Module.get_attribute(env.module, :bond_state_invariants) || []) ++
          (Module.get_attribute(env.module, :bond_transition_invariants) || [])

      case orphans do
        [] ->
          :ok

        [assertion | _] ->
          attr =
            if assertion.kind == :state_invariant,
              do: "@state_invariant",
              else: "@transition_invariant"

          IO.warn(
            "#{attr} was declared in #{inspect(env.module)}, which does not `use Bond.Server`. " <>
              "State and transition invariants are enforced only in a Bond.Server module; this " <>
              "declaration is ignored. Add `use Bond.Server` (after `use GenServer`).",
            assertion.definition_env
          )
      end
    end
  end

  @doc false
  def register_doc(env, meta, value) do
    FSM.doc_attribute(fsm(env), {meta, value})
  end

  @doc false
  def check_assertion(expression, label, env, meta, mode) when mode in [true, false] do
    body = check_body(expression, label, env, meta)

    quote do
      if Bond.Runtime.Eval.should_evaluate?(:checks, unquote(mode)) do
        Bond.Runtime.Eval.evaluate_check(fn -> unquote(body) end)
      else
        :ok
      end
    end
  end

  # `check where(binding, …)`/`whenever(binding, …)` (#47): the all-inside binding form, evaluated
  # as a scoped group (members run inside the `case`, so the bindings don't leak). Any other
  # expression is an ordinary single check.
  defp check_body({binder, _, [binding | scoped]}, _label, env, meta)
       when binder in [:where, :whenever] do
    Assertion.check_group_body(binder, binding, scoped, env, meta)
  end

  defp check_body(expression, label, env, meta) do
    Assertion.check_body(Assertion.new(:check, label, expression, env, meta))
  end

  @spec fsm(Macro.Env.t()) :: FSM.server_ref()
  defp fsm(%Macro.Env{module: module}), do: FSM.server_ref(module)
end
