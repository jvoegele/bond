defmodule Bond.Compiler do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts for a module at compile-time.

  Bond installs this module as the `@on_definition`, `@before_compile`, and `@after_compile`
  handler for any module that does `use Bond`. As the user's module is being compiled:

    * `@pre`, `@post`, and `@doc` annotations are intercepted by `Bond` and forwarded here via
      `register_assertion/5` and `register_doc/3`. They accumulate in the per-module
      `Bond.Compiler.CompileStateFSM` process.
    * Every `def` and `defp` definition fires `__on_definition__/6`, which builds a
      `Bond.Compiler.FunctionDefinition` and feeds it to the FSM. The FSM groups clauses by
      `{module, fun, arity}` and attaches any pending preconditions/postconditions/docs to the
      resulting `Bond.Compiler.AnnotatedFunction`.
    * `__before_compile__/1` asks the FSM for every `AnnotatedFunction` that has a contract and
      delegates to `AnnotatedFunction.apply_contract/1` to emit a `defoverridable` plus a
      single override clause that wraps the original function in pre/post evaluation.
    * `__after_compile__/2` stops the FSM process.
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Boundaries
  # `require` (not `alias`) so Mix creates a strong compile-time dep on
  # CompileStateFSM and schedules compile_state_fsm.ex (and transitively
  # server.ex) before this file. User modules have compile deps on Bond.Compiler
  # via @before_compile/@on_definition; requiring CompileStateFSM here ensures
  # the gen_statem and its callback module are on disk before they are started.
  require Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.ContractDocs
  alias Bond.Compiler.EnvSnapshot
  alias Bond.Compiler.FunctionDefinition
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context
  alias Bond.Compiler.NamedContracts

  # Functions Elixir auto-generates as a side effect of constructs like `defstruct` and
  # `defexception`. These show up via `@on_definition` and must not be tracked as user
  # contract candidates.
  @generated_functions ~w[__struct__ __exception__ __info__]a

  @doc false
  def init(module) do
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
  Per-kind compilation mode. See `Bond.Compiler.AnnotatedFunction.mode/0`.
  """
  @type mode :: true | false | :purge

  @typedoc """
  Resolved per-module configuration produced by `resolve_config/3` and stashed in the
  using module's `@__bond_contract_config__` attribute.
  """
  @type contract_config :: %{
          preconditions: mode(),
          postconditions: mode(),
          checks: mode(),
          invariants: mode(),
          warn_skipped_invariants: boolean()
        }

  @doc """
  Resolve the final per-module contract configuration from global defaults, `:overrides`,
  and the options passed to `use Bond`.

  Precedence (most specific wins):

    1. `use Bond, preconditions: …` options on the using module.
    2. An `:overrides` entry whose key is an exact module atom match.
    3. An `:overrides` entry whose key is a `Regex` that matches the module name
       (first matching pattern in list order wins).
    4. The global `:bond, :preconditions` / `:postconditions` / `:checks` config.

  `:overrides` is a list of `{Module | Regex, keyword_of_settings}` tuples, e.g.:

      config :bond,
        overrides: [
          {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
          {~r/Workers\\./, postconditions: false}
        ]
  """
  @spec resolve_config(module(), keyword(), keyword()) :: contract_config()
  def resolve_config(module, use_opts, global) do
    overrides = Keyword.get(global, :overrides, [])

    base = %{
      preconditions: Keyword.fetch!(global, :preconditions),
      postconditions: Keyword.fetch!(global, :postconditions),
      checks: Keyword.fetch!(global, :checks),
      invariants: Keyword.get(global, :invariants, true),
      warn_skipped_invariants: Keyword.get(global, :warn_skipped_invariants, true)
    }

    resolved =
      base
      |> apply_settings(resolve_overrides_for(overrides, module))
      |> apply_settings(use_opts)

    validate_chain!(module, resolved)
    resolved
  end

  # The contract-checking chain is `preconditions ≤ postconditions ≤ invariants`. If a
  # lower kind is `:purge`, every higher kind must also be `:purge` — there's no
  # meaningful way to compile invariant or postcondition evaluation into the BEAM while
  # the preconditions they presuppose are absent. (`:checks` is independent of the chain.)
  #
  # The runtime half of the constraint — `false` at runtime for a lower kind skipping the
  # higher kinds — is enforced in `Bond.Runtime.Eval.should_evaluate?/3`.
  defp validate_chain!(module, config) do
    chain = [:preconditions, :postconditions, :invariants]

    Enum.reduce(chain, [], fn kind, lower_kinds ->
      if config[kind] != :purge do
        for lower <- lower_kinds, config[lower] == :purge do
          raise CompileError,
            description: chain_error_message(module, kind, lower)
        end
      end

      [kind | lower_kinds]
    end)

    :ok
  end

  defp chain_error_message(module, higher, lower) do
    """
    Bond: contract-checking chain violated for #{inspect(module)}.

    `:#{higher}` is compiled in, but `:#{lower}` is `:purge`d. The chain
    `preconditions ≤ postconditions ≤ invariants` requires that if a higher kind is
    in the BEAM, all lower kinds it presupposes must also be compiled in.

    A `:#{higher}` failure is only meaningful if `:#{lower}` was first verified — without
    `:#{lower}`, a `:#{higher}` error could really be the caller's fault, not the callee's.

    Resolutions:

      * If you want to skip `:#{higher}` evaluation but keep the code, use
        `:#{higher}` => `false` (compiled in, runtime-disabled by default).
      * If you genuinely want `:#{lower}` purged, also purge every higher kind:
        `:#{lower}` => `:purge`, `:#{higher}` => `:purge`.
    """
  end

  defp resolve_overrides_for(overrides, module) do
    case Enum.find(overrides, &exact_match?(&1, module)) do
      {_, opts} ->
        opts

      nil ->
        case Enum.find(overrides, &regex_match?(&1, module)) do
          {_, opts} -> opts
          nil -> []
        end
    end
  end

  defp exact_match?({atom, _opts}, module) when is_atom(atom), do: atom == module
  defp exact_match?(_, _), do: false

  defp regex_match?({%Regex{} = pattern, _opts}, module) do
    Regex.match?(pattern, module_name_for_match(module))
  end

  defp regex_match?(_, _), do: false

  # Module atoms in the BEAM are stored as `"Elixir.MyApp.Foo"`. Strip the `Elixir.` prefix
  # before regex matching so users can write patterns against the source-visible names like
  # `~r/^MyApp\.Workers\./` (rather than `~r/^Elixir\.MyApp\.Workers\./`).
  defp module_name_for_match(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp apply_settings(config, settings) do
    config
    |> apply_kind_settings(settings)
    |> apply_boolean_settings(settings, [:warn_skipped_invariants])
  end

  defp apply_kind_settings(config, settings) do
    Enum.reduce([:preconditions, :postconditions, :checks, :invariants], config, fn key, acc ->
      case Keyword.fetch(settings, key) do
        {:ok, value} when value in [true, false, :purge] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp apply_boolean_settings(config, settings, keys) do
    Enum.reduce(keys, config, fn key, acc ->
      case Keyword.fetch(settings, key) do
        {:ok, value} when is_boolean(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

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
      |> FunctionDefinition.put_external_override(external_override?)

    FSM.function_def(fsm(env), function_def)
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    :ok = FSM.module_defined(fsm(env))

    config =
      Module.get_attribute(env.module, :__bond_contract_config__) ||
        %{preconditions: true, postconditions: true, invariants: true}

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
      |> Enum.map(&merge_inherited_contract(&1, inherited))
      |> Enum.map(&merge_applied_contract(&1, inherited, named))
      |> Enum.map(&AnnotatedFunction.put_invariants(&1, invariants))
      |> Enum.filter(&AnnotatedFunction.override?/1)

    contract_overrides =
      annotated
      |> Enum.map(&AnnotatedFunction.apply_contract(&1, config))
      |> Enum.reject(&is_nil/1)

    named_contracts_ast = build_named_contracts_reflection(named)
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

  # Emits the `__bond_named_contracts__/0` reflection for a module that declared `defcontract`s,
  # so other modules can read them at their own compile time via `@apply_contract {Mod, :name}`
  # (the same role `__bond_contracts__/0` plays for `Bond.Behaviour`). The live `Macro.Env` on
  # each captured assertion is reduced to an escapable snapshot first. Modules with no named
  # contracts emit nothing; `@apply_contract` resolution guards remote reads with
  # `function_exported?/3`.
  defp build_named_contracts_reflection(named) do
    case named do
      empty when map_size(empty) == 0 ->
        nil

      entries ->
        contracts =
          Map.new(entries, fn {key, entry} ->
            # `entry` is already the flattened {arg_names, preconditions, postconditions} shape
            # (includes expanded into pre/post); just snapshot the assertions' live envs.
            {key, EnvSnapshot.sanitize_contract_entry(entry)}
          end)

        quote do
          @doc false
          def __bond_named_contracts__, do: unquote(Macro.escape(contracts))
        end
    end
  end

  # Attaches a behaviour's inherited contracts to the matching implementation function. The
  # match is purely on `{name, arity}` — independent of whether the impl wrote `@impl true`,
  # and triggered only for callbacks the module actually implements (so optional callbacks the
  # impl skips contribute nothing).
  #
  # An impl may not attach a *plain* `@pre`/`@post` to an inherited operation (it would strengthen
  # the inherited precondition, breaking Liskov substitutability) — that stays a compile error.
  # It MAY deliberately refine the inherited contract with `@pre_weaken` (effective pre =
  # inherited OR weaken) or `@post_strengthen` (effective post = inherited AND strengthen) (#16);
  # those are partitioned off here and folded by the codegen. A refinement that targets a
  # non-inherited function, or a `@pre_weaken` with no inherited precondition to weaken, is itself
  # a compile error.
  #
  # A function that applies a named contract (`@apply_contract`, #35) is handled entirely by
  # `merge_applied_contract/2`, which owns its own diagnostics and v1 constraints; skip it here so
  # the two paths never both process one function (combining the two is itself a v1 non-goal, caught
  # in `merge_applied_contract/2`).
  defp merge_inherited_contract(%AnnotatedFunction{applied_contracts: [_ | _]} = af, _inherited),
    do: af

  defp merge_inherited_contract(%AnnotatedFunction{} = annotated_function, inherited) do
    key = {annotated_function.fun, annotated_function.arity}

    {plain_pre, weaken_pre} = partition_refinements(annotated_function.preconditions)
    {plain_post, strengthen_post} = partition_refinements(annotated_function.postconditions)

    case Map.fetch(inherited, key) do
      :error ->
        # Not an inherited operation: `@pre_weaken`/`@post_strengthen` have nothing to refine.
        if weaken_pre != [] or strengthen_post != [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: nothing_to_refine_message(annotated_function)
        end

        annotated_function

      {:ok, %{arg_names: names, preconditions: inherited_pre, postconditions: inherited_post}} ->
        if plain_pre != [] or plain_post != [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: immutable_contract_message(annotated_function)
        end

        if weaken_pre != [] and inherited_pre == [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: nothing_to_weaken_message(annotated_function)
        end

        reject_old_in_strengthen!(strengthen_post, annotated_function)

        validate_refinement_references!(
          weaken_pre,
          strengthen_post,
          key,
          names,
          annotated_function
        )

        annotated_function
        |> AnnotatedFunction.replace_preconditions(inherited_pre)
        |> AnnotatedFunction.replace_postconditions(inherited_post)
        |> AnnotatedFunction.put_pre_weaken(weaken_pre)
        |> AnnotatedFunction.put_post_strengthen(strengthen_post)
        |> AnnotatedFunction.put_canonical_override(names)
    end
  end

  # Resolves and folds an applied named contract (`@apply_contract`, #35) into a function. Kept
  # separate from `merge_inherited_contract/2` (Option B): it speaks in "contract" terms and makes
  # the v1 non-goals explicit compile errors. The fold itself is identical in spirit to inheriting
  # a behaviour contract verbatim — replace the function's pre/post with the contract's and rebind
  # parameters to the contract's canonical argument names positionally.
  defp merge_applied_contract(%AnnotatedFunction{applied_contracts: []} = af, _inherited, _named),
    do: af

  defp merge_applied_contract(
         %AnnotatedFunction{applied_contracts: applied} = af,
         inherited,
         named
       ) do
    key = {af.fun, af.arity}
    [%{env: apply_env} | _] = applied

    # v1 non-goal: an applied contract cannot be combined with behaviour/protocol inheritance.
    if Map.has_key?(inherited, key) do
      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: #{mfa(af)} both inherits a behaviour contract and applies a named contract " <>
            "(@apply_contract). Combining the two on one function is not supported (v1); use one " <>
            "or the other."
    end

    # v1 non-goal: a single applied contract per function (composing several would require the
    # canonical-name agreement / multi-binding the immutable v1 deliberately omits).
    if length(applied) > 1 do
      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: #{mfa(af)} applies more than one named contract. Applying multiple named " <>
            "contracts to one function is not supported (v1); apply a single contract."
    end

    [%{ref: ref}] = applied
    {contract_module, name, entry} = resolve_applied_ref(ref, key, af, named, apply_env)

    {plain_pre, weaken_pre} = partition_refinements(af.preconditions)
    {plain_post, strengthen_post} = partition_refinements(af.postconditions)

    label = contract_label(contract_module, name, af.module)

    # Deferred (#40): refining an applied contract with @pre_weaken/@post_strengthen (the OR/weaken
    # case). Additive plain @pre/@post (below) covers the common "also require X" need; weakening
    # stays a compile error for now.
    if weaken_pre != [] or strengthen_post != [] do
      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: #{mfa(af)} refines the applied named contract #{label} with " <>
            "@pre_weaken/@post_strengthen. Refining a named contract is not supported (v1)."
    end

    # #40 Option A: the function's own plain @pre/@post ADD to the applied contract (conjunction).
    # They evaluate in the lifted assertion defp, which is parameterised by the contract's canonical
    # argument names — so they must reference those names, not the function's own parameters. Validate
    # that here (a clear error beats an "undefined variable" deep in generated code), then append them
    # UNSTAMPED so a failure attributes to the function itself, not the contract.
    validate_applied_extension_refs!(
      plain_pre,
      plain_post,
      {af.fun, af.arity},
      entry.arg_names,
      apply_env
    )

    source = {contract_module, name}

    af
    |> AnnotatedFunction.replace_preconditions(
      stamp_source_contract(entry.preconditions, source) ++ plain_pre
    )
    |> AnnotatedFunction.replace_postconditions(
      stamp_source_contract(entry.postconditions, source) ++ plain_post
    )
    |> AnnotatedFunction.put_canonical_override(entry.arg_names)
  end

  defp validate_applied_extension_refs!([], [], _key, _arg_names, _env), do: :ok

  defp validate_applied_extension_refs!(plain_pre, plain_post, key, arg_names, env) do
    InheritedContracts.validate_referenced_names!(
      applied_extension_ctx(),
      plain_pre,
      plain_post,
      key,
      arg_names,
      env
    )
  end

  # Reference-validation context for plain @pre/@post added alongside an @apply_contract (#40). Uses
  # only the diagnostic-wording fields and `reject_old` (false: `old/1` is fine in an added @post,
  # same as on any ordinary function); the pending-key fields are required by the struct but unused.
  defp applied_extension_ctx do
    %Context{
      noun: "contract",
      contract_subject: "function applying a named contract",
      reference_scope: "the applied contract's argument names",
      pending_pre_key: :__bond_applied_extension_pending_pre__,
      pending_post_key: :__bond_applied_extension_pending_post__,
      reject_old: false,
      arg_naming_hint?: false
    }
  end

  defp resolve_applied_ref(
         {:local, name},
         {_fun, arity},
         %AnnotatedFunction{module: module},
         named,
         env
       ) do
    fetch_applied_entry(named, name, arity, module, env)
  end

  defp resolve_applied_ref({:remote, contract_module, name}, {_fun, arity}, _af, _named, env) do
    Code.ensure_compiled!(contract_module)

    unless function_exported?(contract_module, :__bond_named_contracts__, 0) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: @apply_contract {#{inspect(contract_module)}, #{inspect(name)}} — " <>
            "#{inspect(contract_module)} defines no named contracts (no `defcontract`, or it does " <>
            "not `use Bond`)."
    end

    contract_module.__bond_named_contracts__()
    |> fetch_applied_entry(name, arity, contract_module, env)
  end

  defp fetch_applied_entry(registry, name, arity, contract_module, env) do
    case Map.fetch(registry, {name, arity}) do
      {:ok, entry} ->
        {contract_module, name, entry}

      :error ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: unknown_applied_contract_message(registry, name, arity, contract_module)
    end
  end

  defp unknown_applied_contract_message(registry, name, arity, contract_module) do
    available =
      registry
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {n, a} -> "#{n}/#{a}" end)

    available_phrase =
      if available == "", do: "it defines no named contracts", else: "available: #{available}"

    "Bond: no named contract #{name}/#{arity} in #{inspect(contract_module)} (#{available_phrase})."
  end

  defp stamp_source_contract(assertions, source) do
    Enum.map(assertions, fn assertion -> %{assertion | source_contract: source} end)
  end

  defp contract_label(contract_module, name, function_module) do
    if contract_module == function_module,
      do: inspect(name),
      else: "#{inspect(contract_module)}.#{name}"
  end

  defp mfa(%AnnotatedFunction{module: module, fun: fun, arity: arity}),
    do: "#{inspect(module)}.#{fun}/#{arity}"

  # Splits a function's own assertions into {plain, refinement} by the `:refinement` tag the
  # `@pre_weaken`/`@post_strengthen` macros set (`nil` => plain `@pre`/`@post`).
  defp partition_refinements(assertions) do
    Enum.split_with(assertions, fn %Assertion{refinement: r} -> is_nil(r) end)
  end

  # `@post_strengthen` runs in the lifted postcondition defp without `old/1` precompilation, so
  # reject `old(...)` rather than letting it surface as an "undefined function old/1" deep in
  # generated code. The inherited postcondition may still use `old/1` as before.
  defp reject_old_in_strengthen!(strengthen_post, annotated_function) do
    if Enum.any?(strengthen_post, &uses_old?(&1.expression)) do
      raise CompileError,
        file: inherited_violation_file(annotated_function),
        line: inherited_violation_line(annotated_function),
        description: old_in_strengthen_message(annotated_function)
    end

    :ok
  end

  defp uses_old?(expression) do
    {_, found?} =
      Macro.prewalk(expression, false, fn
        {:old, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # `@pre_weaken`/`@post_strengthen` reference the abstraction's canonical argument names — the same
  # names the inherited contract uses — so validate them against those names (plus `result` in the
  # strengthening postcondition). Caught here, a typo points at the refinement; left to the codegen
  # it would surface as an opaque "undefined variable" inside the generated lifted defp. Shares the
  # protocol path's `InheritedContracts.validate_referenced_names!` so both flavours diagnose
  # bad references identically.
  defp validate_refinement_references!([], [], _key, _names, _annotated_function), do: :ok

  defp validate_refinement_references!(
         weaken_pre,
         strengthen_post,
         key,
         names,
         annotated_function
       ) do
    [clause | _] = annotated_function.clauses

    InheritedContracts.validate_referenced_names!(
      refinement_ctx(),
      weaken_pre,
      strengthen_post,
      key,
      names,
      clause.env
    )
  end

  # The few `Context` fields that shape the unknown-reference diagnostic for a behaviour-impl
  # refinement. `reject_old` stays `false`: `old/1` in `@post_strengthen` is rejected separately by
  # `reject_old_in_strengthen!/2`, and the inherited `@post` may legitimately use it. The pending
  # keys are required by the struct but unused by `validate_referenced_names!`.
  defp refinement_ctx do
    %Context{
      noun: "callback",
      contract_subject: "behaviour implementation",
      reference_scope: "the callback's named arguments",
      pending_pre_key: :__bond_pending_pre__,
      pending_post_key: :__bond_pending_post__,
      stamp_source_behaviour: false,
      reject_old: false,
      arg_naming_hint?: false
    }
  end

  defp inherited_violation_file(%AnnotatedFunction{clauses: [clause | _]}), do: clause.env.file
  defp inherited_violation_file(_), do: nil

  defp inherited_violation_line(%AnnotatedFunction{clauses: [clause | _]}), do: clause.env.line
  defp inherited_violation_line(_), do: nil

  defp immutable_contract_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` inherits a contract from a behaviour, so it may not declare its " <>
      "own `@pre`/`@post` (a plain impl-level precondition would strengthen the inherited one, " <>
      "violating Liskov substitutability). To deliberately refine the inherited contract, use " <>
      "`@pre_weaken` (weakens the inherited precondition) or `@post_strengthen` (strengthens the " <>
      "inherited postcondition). For an implementation-specific assertion independent of the " <>
      "contract, use `check/1` in the function body instead."
  end

  defp nothing_to_refine_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` uses `@pre_weaken`/`@post_strengthen` but inherits no contract to " <>
      "refine. Refinement only applies to a function that inherits a `@pre`/`@post` from a " <>
      "behaviour callback. Use plain `@pre`/`@post` for a contract on a non-inherited function."
  end

  defp nothing_to_weaken_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` uses `@pre_weaken` but the inherited contract declares no " <>
      "precondition to weaken. An implementation may not introduce a precondition on an " <>
      "inherited operation — that would strengthen it, violating Liskov substitutability. " <>
      "Use `@post_strengthen` to strengthen the postcondition, or `check/1` in the body for an " <>
      "implementation-specific assertion."
  end

  defp old_in_strengthen_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: the `@post_strengthen` on `#{fun}/#{arity}` uses `old/1`, which is not supported in a " <>
      "refinement postcondition. `old/1` is available in the inherited `@post` (on the behaviour " <>
      "callback) but not in the implementation's `@post_strengthen`."
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

  @doc false
  def register_assertion(:pre, expression, label, env, meta) do
    register_assertion(:precondition, expression, label, env, meta)
  end

  def register_assertion(:post, expression, label, env, meta) do
    register_assertion(:postcondition, expression, label, env, meta)
  end

  def register_assertion(kind, expression, label, env, meta) do
    register_assertion(kind, expression, label, env, meta, nil)
  end

  @doc false
  def register_assertion(kind, expression, label, env, meta, refinement)
      when kind in [:precondition, :postcondition] do
    Assertion.validate_expression!(expression, env)

    assertion =
      Assertion.new(kind, label, expression, env, meta)
      |> maybe_put_refinement(refinement)

    fsm_event =
      case kind do
        :precondition -> :precondition_def
        :postcondition -> :postcondition_def
      end

    apply(FSM, fsm_event, [fsm(env), assertion])
  end

  defp maybe_put_refinement(assertion, nil), do: assertion

  defp maybe_put_refinement(assertion, refinement),
    do: Assertion.put_refinement(assertion, refinement)

  @doc false
  # Records an `@apply_contract` reference against the next function definition. The reference
  # normalises to `{:local, name}` or `{:remote, module, name}` (the module alias is expanded in
  # the caller's context now, establishing the compile-time dependency for the cross-module read
  # that resolution performs at `__before_compile__`). Arity is not known here; it comes from the
  # function the reference attaches to. v1 applies a single contract per function, so there is no
  # list form (applying multiple contracts is a documented non-goal).
  def register_apply_contract(expression, %Macro.Env{} = env, meta) do
    ref = parse_apply_contract_ref(expression, env)
    line = Keyword.get(meta, :line, env.line)
    FSM.apply_contract_def(fsm(env), %{ref: ref, line: line, env: env})
    :ok
  end

  defp parse_apply_contract_ref(name, _env) when is_atom(name), do: {:local, name}

  defp parse_apply_contract_ref({module_ast, name}, env) when is_atom(name) do
    {:remote, Macro.expand(module_ast, env), name}
  end

  defp parse_apply_contract_ref(list, env) when is_list(list) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: @apply_contract takes a single named contract in v1 (`:name` or " <>
          "`{Module, :name}`). Applying multiple contracts to one function is not supported."
  end

  defp parse_apply_contract_ref(other, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: @apply_contract expects a contract name (`:withdrawal`) or a `{Module, :name}` " <>
          "pair. Got: `#{Macro.to_string(other)}`."
  end

  @doc false
  def register_invariant(expression, label, env, meta) do
    Assertion.validate_expression!(expression, env)
    # Strip the hygiene context off every reference to `subject` so they resolve to the
    # `subject` variable rebound by `Bond.Compiler.Assertion.invariants_body/2`
    # (which uses `Macro.var(:subject, nil)`). Without this, references inherited from
    # the macro's expansion context would not resolve to the rebind.
    normalized = normalize_subject_context(expression)
    invariant = Assertion.new(:invariant, label, normalized, env, meta)
    FSM.invariant_def(fsm(env), invariant)
  end

  defp normalize_subject_context(expression) do
    Macro.prewalk(expression, fn
      {:subject, meta, ctx} when is_atom(ctx) ->
        {:subject, meta, nil}

      other ->
        other
    end)
  end

  @doc false
  def register_doc(env, meta, value) do
    FSM.doc_attribute(fsm(env), {meta, value})
  end

  @doc false
  def check_assertion(expression, label, env, meta, mode) when mode in [true, false] do
    check = Assertion.new(:check, label, expression, env, meta)
    body = Assertion.check_body(check)

    quote do
      if Bond.Runtime.Eval.should_evaluate?(:checks, unquote(mode)) do
        Bond.Runtime.Eval.evaluate_check(fn -> unquote(body) end)
      else
        :ok
      end
    end
  end

  @spec fsm(Macro.Env.t()) :: FSM.server_ref()
  defp fsm(%Macro.Env{module: module}), do: FSM.server_ref(module)
end
