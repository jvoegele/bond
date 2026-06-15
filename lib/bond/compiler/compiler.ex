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
  # `require` (not `alias`) so Mix creates a strong compile-time dep on
  # CompileStateFSM and schedules compile_state_fsm.ex (and transitively
  # server.ex) before this file. User modules have compile deps on Bond.Compiler
  # via @before_compile/@on_definition; requiring CompileStateFSM here ensures
  # the gen_statem and its callback module are on disk before they are started.
  require Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.ContractDocs
  alias Bond.Compiler.FunctionDefinition
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context

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

    contract_overrides =
      fsm(env)
      |> FSM.annotated_functions()
      |> Enum.map(&merge_inherited_contract(&1, inherited))
      |> Enum.map(&AnnotatedFunction.put_invariants(&1, invariants))
      |> Enum.filter(&AnnotatedFunction.override?/1)
      |> Enum.map(&AnnotatedFunction.apply_contract(&1, config))
      |> Enum.reject(&is_nil/1)

    case moduledoc_invariants_ast do
      nil -> contract_overrides
      ast -> [ast | contract_overrides]
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
