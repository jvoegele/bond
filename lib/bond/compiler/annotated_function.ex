defmodule Bond.Compiler.AnnotatedFunction do
  @moduledoc internal: true
  @moduledoc """
  Internal model of a user function plus everything attached to it at compile time: its clauses,
  its preconditions, its postconditions, and any `@doc` attributes that precede it.

  All clauses of a function (with the same name and arity) are gathered into one
  `AnnotatedFunction` struct. The `:clauses` field holds an ordered list of
  `Bond.Compiler.AnnotatedFunction.Clause` structs, one per `def`/`defp` clause. The
  `:preconditions`, `:postconditions`, and `:doc_attributes` fields apply to all clauses.

  An `AnnotatedFunction` is produced by `Bond.Compiler.CompileStateFSM` from the
  `Bond.Compiler.FunctionDefinition` events emitted by `@on_definition`, and consumed by
  `apply_contract/1` in this module to generate the override that wraps the original function in
  pre/post evaluation.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.ClauseWrapper
  alias Bond.Compiler.Clauses
  alias Bond.Compiler.ContractDocs
  alias Bond.Compiler.FunctionDefinition
  alias Bond.Compiler.Invariants
  alias Bond.Compiler.OldExpression
  # `require` (not `alias`) so Mix creates a strong compile-time dep on Clause and schedules
  # clause.ex before this file. This is required on Elixir 1.19+ where the parallel compiler
  # can write AnnotatedFunction.beam to disk before AnnotatedFunction.Clause.beam, causing
  # AnnotatedFunction.Clause.new/1 to be unavailable when the gen_statem calls it.
  require Bond.Compiler.AnnotatedFunction.Clause, as: Clause

  defstruct kind: nil,
            module: nil,
            fun: nil,
            arity: nil,
            clauses: [],
            preconditions: [],
            postconditions: [],
            invariants: [],
            doc_attributes: [],
            # For functions inheriting a behaviour's callback contracts: the canonical
            # positional names dictated by the callback (the contract expressions reference
            # these). When set, the wrapper binds the impl's parameters to these names
            # positionally and the multi-clause name-agreement check is bypassed — there is
            # nothing to negotiate, the callback dictates the names. `nil` for ordinary
            # functions, which derive canonical names from their own clauses.
            canonical_names_override: nil,
            # Impl-authored refinement assertions (#16). When either is non-empty the function
            # *refines* an inherited contract: `@pre_weaken` weakens the inherited precondition
            # (effective pre = inherited OR pre_weaken) and `@post_strengthen` strengthens the
            # inherited postcondition (effective post = inherited AND post_strengthen). Their
            # expressions reference the implementation's own parameter names; `preconditions` /
            # `postconditions` hold the inherited (canonical-named) assertions they fold against.
            pre_weaken_assertions: [],
            post_strengthen_assertions: []

  @type t :: %__MODULE__{
          kind: :def | :defp | nil,
          module: module() | nil,
          fun: atom() | nil,
          arity: non_neg_integer() | nil,
          clauses: [__MODULE__.Clause.t()],
          preconditions: [Bond.Compiler.Assertion.t()],
          postconditions: [Bond.Compiler.Assertion.t()],
          invariants: [Bond.Compiler.Assertion.t()],
          doc_attributes: [FunctionDefinition.doc_attribute()],
          canonical_names_override: [atom()] | nil,
          pre_weaken_assertions: [Bond.Compiler.Assertion.t()],
          post_strengthen_assertions: [Bond.Compiler.Assertion.t()]
        }

  def new(%FunctionDefinition{} = function_def) do
    %__MODULE__{
      kind: function_def.kind,
      module: function_def.module,
      fun: function_def.fun,
      arity: function_def.arity,
      clauses: [Clause.new(function_def)]
    }
  end

  def mfa(%__MODULE__{module: module, fun: function, arity: arity}), do: {module, function, arity}

  def add_clause(
        %__MODULE__{module: module, fun: function, arity: arity, clauses: clauses} = function_def,
        %FunctionDefinition{module: module, fun: function, arity: arity} = clause_def
      ) do
    %{function_def | clauses: clauses ++ [Clause.new(clause_def)]}
  end

  def put_preconditions(%__MODULE__{preconditions: existing} = annotated_function, preconditions)
      when is_list(preconditions) do
    %{
      annotated_function
      | preconditions: existing ++ validate_all!(preconditions, fn %Assertion{} -> :ok end)
    }
  end

  def put_postconditions(
        %__MODULE__{postconditions: existing} = annotated_function,
        postconditions
      )
      when is_list(postconditions) do
    %{
      annotated_function
      | postconditions: existing ++ validate_all!(postconditions, fn %Assertion{} -> :ok end)
    }
  end

  def put_invariants(%__MODULE__{invariants: existing} = annotated_function, invariants)
      when is_list(invariants) do
    %{
      annotated_function
      | invariants:
          existing ++ validate_all!(invariants, fn %Assertion{kind: :invariant} -> :ok end)
    }
  end

  # Raises (a MatchError from `validator`) unless every element is the expected assertion struct —
  # preconditions/postconditions any `Assertion`, invariants an `Assertion` of `kind: :invariant`.
  # Returns the list unchanged so callers can append it inline.
  defp validate_all!(assertions, validator) do
    Enum.each(assertions, validator)
    assertions
  end

  def put_doc_attributes(
        %__MODULE__{doc_attributes: existing_doc_attributes} = annotated_function,
        doc_attributes
      )
      when is_list(doc_attributes) do
    %{annotated_function | doc_attributes: existing_doc_attributes ++ doc_attributes}
  end

  @doc """
  Sets the canonical positional names for a function inheriting behaviour contracts.

  See the `:canonical_names_override` field: the names come from the inherited callback and
  dictate how the wrapper rebinds the implementation's parameters.
  """
  def put_canonical_override(%__MODULE__{} = annotated_function, names) when is_list(names) do
    %{annotated_function | canonical_names_override: names}
  end

  @doc """
  Replaces the precondition/postcondition lists outright (vs the appending `put_*` setters).

  Used by `Bond.Compiler.merge_inherited_contract/2` when folding a refinement: the impl's own
  `@pre_weaken`/`@post_strengthen` assertions are moved off `preconditions`/`postconditions`
  (where the FSM placed them) into the dedicated refinement fields, and these fields are reset to
  hold only the inherited (canonical-named) assertions they fold against.
  """
  def replace_preconditions(%__MODULE__{} = annotated_function, preconditions)
      when is_list(preconditions),
      do: %{annotated_function | preconditions: preconditions}

  def replace_postconditions(%__MODULE__{} = annotated_function, postconditions)
      when is_list(postconditions),
      do: %{annotated_function | postconditions: postconditions}

  @doc """
  Sets the impl's `@pre_weaken` / `@post_strengthen` refinement assertions (#16). These reference
  the implementation's own parameter names and fold against the inherited contract at codegen.
  """
  def put_pre_weaken(%__MODULE__{} = annotated_function, assertions) when is_list(assertions),
    do: %{annotated_function | pre_weaken_assertions: assertions}

  def put_post_strengthen(%__MODULE__{} = annotated_function, assertions)
      when is_list(assertions),
      do: %{annotated_function | post_strengthen_assertions: assertions}

  def has_pre_weaken?(%__MODULE__{pre_weaken_assertions: a}), do: not Enum.empty?(a)
  def has_post_strengthen?(%__MODULE__{post_strengthen_assertions: a}), do: not Enum.empty?(a)

  def has_preconditions?(%__MODULE__{preconditions: preconditions}),
    do: not Enum.empty?(preconditions)

  def has_postconditions?(%__MODULE__{postconditions: postconditions}),
    do: not Enum.empty?(postconditions)

  def has_invariants?(%__MODULE__{invariants: invariants}),
    do: not Enum.empty?(invariants)

  def has_doc_attributes?(%__MODULE__{doc_attributes: doc_attributes}),
    do: not Enum.empty?(doc_attributes)

  def override?(%__MODULE__{} = annotated_function) do
    has_preconditions?(annotated_function) or
      has_postconditions?(annotated_function) or
      has_pre_weaken?(annotated_function) or
      has_post_strengthen?(annotated_function) or
      (annotated_function.kind == :def and has_invariants?(annotated_function))
  end

  @typedoc """
  Per-kind configuration mode controlling how `apply_contract/2` emits each contract kind:

    * `true` — emit the override with a runtime guard that defaults to "evaluate."
    * `false` — emit the override with a runtime guard that defaults to "do not evaluate."
    * `:purge` — emit no code for this kind. The override may still be emitted for the
      *other* kind, in which case the doc section for the purged kind is also omitted.

  `true` and `false` both produce code that reads `Application.get_env(:bond, <kind>, default)`
  at every call, where `default` is the compile-time value. Anything other than `false` at
  runtime causes evaluation to occur, so the toggle is "set to `false` to disable."
  """
  @type mode :: true | false | :purge

  @typedoc """
  Configuration controlling which kinds of contracts `apply_contract/2` emits and how.

  Used by `Bond.Compiler.__before_compile__/1` to honour the `:bond` application config keys
  `:preconditions` and `:postconditions` (and any per-module `:overrides`).
  """
  @type contract_config :: %{
          required(:preconditions) => mode(),
          required(:postconditions) => mode(),
          optional(:invariants) => mode()
        }

  @doc """
  Returns a quoted expression that wraps the annotated function with its contract, or `nil`
  when nothing needs to be emitted.

  Per-kind mode (see `t:mode/0`):

    * `true` / `false` — the override IS emitted; `Bond.Runtime.Eval` performs a runtime
      `Application.get_env(:bond, <kind>, <compile_time_value>)` check and skips evaluation
      when the result is exactly `false`. The auto-generated doc section for that kind
      appears.
    * `:purge` — no code is emitted for that kind. The doc section is omitted.

  When both `:preconditions` and `:postconditions` resolve to `:purge` (or when the function
  has no contracts of either kind), `apply_contract/2` returns `nil`. The caller filters
  `nil`s out and the user's `def`/`defp` runs as written, with zero per-call overhead.

  When an override IS emitted, the expression contains:

    1. A `defoverridable` declaration making the function overridable.
    2. Zero or more `@doc` clauses re-emitting the user's `@doc` attributes, with the
       auto-generated `#### Preconditions` / `#### Postconditions` sections appended (filtered
       by the per-kind mode).
    3. A single override clause for the function that:

         * (when `preconditions != :purge`) calls `Bond.Runtime.Eval.evaluate_preconditions/2`
           with a thin closure that delegates to the lifted precondition defp;
         * resolves any `old(...)` expressions found in the postconditions into local bindings;
         * delegates to the original implementation via `super(...)`, capturing the result;
         * (when `postconditions != :purge`) calls `Bond.Runtime.Eval.evaluate_postconditions/2`
           with a thin closure that delegates to the lifted postcondition defp (passing the
           function params, the captured result, and the resolved old-value bindings);
         * returns the captured result.

    4. One private `defp` per non-purged kind containing the assertion-evaluation block
       produced by `Bond.Compiler.Assertion.assertions_body/2`. Naming convention:
       `:"__bond_preconditions__\#{fun}__\#{arity}"` /
       `:"__bond_postconditions__\#{fun}__\#{arity}"`. Lifting the closure body into a named
       defp keeps the override clause itself tiny and avoids re-emitting the full assertion
       AST inline.

  The override clause uses the parameter names from the function's first clause. For
  multi-clause functions Elixir's normal pattern matching applies inside `super(...)`, so a
  single wrapper clause covers every original clause.
  """
  @spec apply_contract(t(), contract_config()) :: Macro.t() | nil
  def apply_contract(annotated_function, config \\ %{preconditions: true, postconditions: true})

  def apply_contract(%__MODULE__{} = annotated_function, config) do
    # A refinement (`@pre_weaken`/`@post_strengthen`) counts as "having" that kind even when the
    # inherited group is empty (e.g. adding a postcondition where the behaviour declared none), so
    # the kind isn't purged out from under it.
    pre_mode =
      resolve_mode(
        Map.fetch!(config, :preconditions),
        has_preconditions?(annotated_function) or has_pre_weaken?(annotated_function)
      )

    post_mode =
      resolve_mode(
        Map.fetch!(config, :postconditions),
        has_postconditions?(annotated_function) or has_post_strengthen?(annotated_function)
      )

    inv_mode =
      Invariants.resolve_mode(
        Map.get(config, :invariants, true),
        annotated_function.kind,
        annotated_function.invariants
      )

    maybe_warn_skipped_invariants(annotated_function, inv_mode, config)

    if pre_mode != :purge or post_mode != :purge or inv_mode != :purge do
      build_contract_override(annotated_function, pre_mode, post_mode, inv_mode)
    end
  end

  # Emits a compile-time warning when a public function in an invariant-declaring
  # module has no clause that exercises ANY invariant check — neither a pre-check
  # (struct in head) nor a statically-detectable post-check (body returns the
  # struct or `{:ok, struct}`). On by default; suppression is layered:
  #
  #   * global:       `config :bond, warn_skipped_invariants: false`
  #   * per-module:   `use Bond, warn_skipped_invariants: false`
  #   * per-function: `@bond_warn_skipped_invariants false` (next def only)
  #
  # The per-function override is tri-state: `nil` (no attribute set) inherits the
  # module/global setting; `true` or `false` overrides for that single function.
  #
  # Triggers ONLY when ALL of:
  #   - the function is `def` (defp is exempt from invariants by design)
  #   - invariants are attached to this function (i.e. module declares @invariant)
  #   - inv_mode != :purge (user hasn't explicitly opted out)
  #   - resolved warn flag is true (per-function override > module/global config)
  #   - no clause has either a struct in head or a statically-detectable struct
  #     return (so invariants are truly skipped both on entry and exit)
  defp maybe_warn_skipped_invariants(
         %__MODULE__{kind: :def, invariants: [_ | _], module: struct_module} = annotated_function,
         inv_mode,
         config
       )
       when inv_mode != :purge do
    warn? = resolve_warn_skipped_invariants(annotated_function.clauses, config)

    if warn? and
         not Invariants.any_clause_checks_invariants?(
           annotated_function.clauses,
           struct_module
         ) do
      first_clause = List.first(annotated_function.clauses)

      IO.warn(
        skipped_invariants_warning_message(annotated_function),
        first_clause.env
      )
    end
  end

  defp maybe_warn_skipped_invariants(_annotated_function, _inv_mode, _config), do: :ok

  # Resolves the final warn-or-not decision. Per-function override (first clause
  # with a non-nil override wins) takes precedence over the module/global config
  # value. If no clause has an override, fall back to the resolved config.
  #
  # Uses an explicit nil check rather than `Enum.find_value/2` because the
  # override is a tri-state (nil | true | false) and `find_value` treats `false`
  # the same as nil — which would silently drop legitimate `false` overrides.
  defp resolve_warn_skipped_invariants(clauses, config) do
    per_function_override =
      clauses
      |> Enum.map(& &1.warn_skipped_invariants_override)
      |> Enum.find(&(&1 != nil))

    case per_function_override do
      nil -> Map.get(config, :warn_skipped_invariants, true)
      bool when is_boolean(bool) -> bool
    end
  end

  defp skipped_invariants_warning_message(%__MODULE__{
         module: module,
         fun: fun,
         arity: arity
       }) do
    "public function `#{fun}/#{arity}` in invariant-declaring module " <>
      "`#{inspect(module)}` has no clause that pattern-matches the struct " <>
      "or returns one; invariants are skipped here. If intentional, " <>
      "suppress with `@bond_warn_skipped_invariants false` (per function), " <>
      "`use Bond, warn_skipped_invariants: false` (per module), or " <>
      "`config :bond, warn_skipped_invariants: false` (globally)."
  end

  # A kind is effectively purged if either the user purged it OR the function has no
  # assertions of that kind — there's nothing to evaluate or document either way.
  defp resolve_mode(:purge, _has_assertions?), do: :purge
  defp resolve_mode(_value, false), do: :purge
  defp resolve_mode(value, true) when value in [true, false], do: value

  defp build_contract_override(
         %__MODULE__{kind: kind, fun: fun, arity: arity, module: struct_module} =
           annotated_function,
         pre_mode,
         post_mode,
         inv_mode
       ) do
    first_clause = List.first(annotated_function.clauses)
    env = first_clause.env

    canonical_names = resolve_canonical_names(annotated_function, {fun, arity})

    {postconditions, old_context} =
      if post_mode != :purge do
        OldExpression.precompile(annotated_function.postconditions)
      else
        OldExpression.precompile([])
      end

    doc_asts = ContractDocs.doc_clauses(annotated_function, env, pre_mode, post_mode)

    {weaken_prelude, strengthen_prelude} =
      refinement_preludes(annotated_function, canonical_names, env, {fun, arity})

    wrapper_context = %{
      fun: fun,
      arity: arity,
      kind: kind,
      struct_module: struct_module,
      pre_mode: pre_mode,
      post_mode: post_mode,
      inv_mode: inv_mode,
      pre_fn_name: lifted_fn_name(:preconditions, fun, arity),
      post_fn_name: lifted_fn_name(:postconditions, fun, arity),
      inv_fn_name: lifted_fn_name(:invariants, fun, arity),
      old_pairs: OldExpression.pairs(old_context),
      old_assignments: OldExpression.resolve(old_context),
      weaken_prelude: weaken_prelude,
      strengthen_prelude: strengthen_prelude
    }

    defp_params = lifted_defp_params(annotated_function, canonical_names, first_clause)

    wrapper_clauses =
      Enum.map(annotated_function.clauses, fn clause ->
        ClauseWrapper.build_wrapper(clause, canonical_names, wrapper_context)
      end)

    assertion_defs =
      build_assertion_defs(annotated_function, postconditions, defp_params, wrapper_context, env)

    quote file: env.file, line: env.line do
      defoverridable([{unquote(fun), unquote(arity)}])

      unquote_splicing(doc_asts)

      unquote_splicing(wrapper_clauses)

      unquote_splicing(assertion_defs)
    end
  end

  # Canonical positional names. For functions inheriting behaviour contracts the names are
  # dictated by the callback (stored in `:canonical_names_override`), so there is nothing to
  # negotiate across clauses — the agreement check is bypassed. Otherwise, require clause-name
  # agreement only at positions whose names appear in some assertion's expression AST: trivial
  # contracts (`@post is_boolean(result)`) don't constrain parameter naming; shape-dependent
  # contracts referencing `x` only constrain the position bound to `x`.
  defp resolve_canonical_names(
         %__MODULE__{canonical_names_override: nil} = annotated_function,
         function_info
       ) do
    first_clause = List.first(annotated_function.clauses)

    referenced_names =
      Clauses.referenced_param_names(
        annotated_function.preconditions ++
          annotated_function.postconditions ++ annotated_function.invariants,
        annotated_function.clauses
      )

    {:ok, names} =
      Clauses.assert_clauses_agree!(
        annotated_function.clauses,
        first_clause.env,
        function_info,
        referenced_names
      )

    names
  end

  defp resolve_canonical_names(%__MODULE__{canonical_names_override: override}, _function_info),
    do: override

  # Lifted-defp parameter strategy depends on whether the function has one clause or many.
  #
  #   * Single-clause: lifted defp's head reproduces the user's pattern, so contracts can
  #     reference destructured names from the head (e.g. `current_count` from
  #     `%__MODULE__{count: current_count} = state`). The wrapper passes the canonical-named
  #     value; the defp re-binds via its pattern.
  #
  #   * Multi-clause: lifted defp's head is just the canonical names as bare vars. Contracts can
  #     only reference top-level names — they must apply uniformly to every clause, so
  #     destructured-name access from any individual clause is unavailable. Shape-dependent
  #     assertions use the `~>` implication operator.
  #
  #   * Inherited contracts: the contract expressions reference the callback's argument names,
  #     not the impl's parameter names, so the lifted defp must take the canonical names as bare
  #     vars regardless of clause count — the same value the wrapper rebinds and passes via the
  #     canonical name.
  defp lifted_defp_params(
         %__MODULE__{canonical_names_override: override},
         canonical_names,
         _first_clause
       )
       when not is_nil(override) do
    Enum.map(canonical_names, &Macro.var(&1, nil))
  end

  defp lifted_defp_params(%__MODULE__{clauses: [_single]}, _canonical_names, first_clause) do
    ClauseWrapper.strip_default_args(first_clause.params)
  end

  defp lifted_defp_params(_annotated_function, canonical_names, _first_clause) do
    Enum.map(canonical_names, &Macro.var(&1, nil))
  end

  defp build_assertion_defs(annotated_function, postconditions, defp_params, wrapper_context, env) do
    function_info = {wrapper_context.fun, wrapper_context.arity}
    struct_module = wrapper_context.struct_module

    [
      build_pre_defp(
        annotated_function,
        defp_params,
        function_info,
        struct_module,
        env,
        wrapper_context
      ),
      build_post_defp(
        annotated_function,
        postconditions,
        defp_params,
        function_info,
        struct_module,
        env,
        wrapper_context
      ),
      Invariants.build_lifted_defp(
        wrapper_context.inv_fn_name,
        annotated_function.invariants,
        function_info,
        env,
        wrapper_context.inv_mode
      )
    ]
    |> Enum.reject(&is_nil/1)
    # Each lifted-defp builder emits a `@dialyzer {:nowarn_function, ...}` attribute immediately
    # followed by the `defp` — a two-statement `__block__`. Flatten those into individual
    # top-level statements so the module body holds the attribute and the defp as siblings
    # (rather than nested blocks).
    |> Enum.flat_map(fn
      {:__block__, _, stmts} -> stmts
      other -> [other]
    end)
  end

  defp lifted_fn_name(kind, fun, arity) do
    :"__bond_#{kind}__#{fun}__#{arity}"
  end

  # Extra parameters that come after the original function's params in the lifted
  # postcondition defp: the captured `result` and one parameter per resolved `old(...)` value,
  # in the order produced by `OldExpression.pairs/1`. All wrapped in `var!/1` so they bind
  # with the calling function's hygiene context (matching how the assertion expressions and
  # `OldExpression.resolve/1` reference them).
  defp postcondition_extra_params(old_pairs) do
    result_param = quote(do: var!(result))
    old_params = for {var, _expression} <- old_pairs, do: quote(do: var!(unquote(var)))
    [result_param | old_params]
  end

  # Precondition defp: the refined (`inherited OR @pre_weaken`) form when a refinement is present,
  # otherwise the ordinary conjunction defp. Both share the lifted-defp name/shape so the wrapper's
  # `evaluate_preconditions(fn -> __bond_preconditions__…() end)` call is unchanged.
  defp build_pre_defp(_af, _params, _info, _module, _env, %{pre_mode: :purge}), do: nil

  defp build_pre_defp(
         %__MODULE__{pre_weaken_assertions: []} = af,
         defp_params,
         info,
         module,
         env,
         wc
       ) do
    maybe_build_assertion_defp(
      wc.pre_fn_name,
      defp_params,
      [],
      af.preconditions,
      info,
      module,
      env,
      wc.pre_mode
    )
  end

  defp build_pre_defp(%__MODULE__{} = af, defp_params, info, module, env, wc) do
    body =
      Assertion.pre_weaken_body(
        af.preconditions,
        af.pre_weaken_assertions,
        wc.weaken_prelude,
        info,
        module
      )

    build_lifted_defp_with_body(wc.pre_fn_name, defp_params, body, env)
  end

  # Postcondition defp: the strengthened (`inherited AND @post_strengthen`) form when a refinement
  # is present, otherwise the ordinary one. `postconditions` is the inherited group, already
  # `OldExpression.precompile`d; `@post_strengthen` assertions carry no `old/1` (rejected at the
  # merge gate) so they need no precompilation.
  defp build_post_defp(_af, _post, _params, _info, _module, _env, %{post_mode: :purge}), do: nil

  defp build_post_defp(
         %__MODULE__{post_strengthen_assertions: []},
         postconditions,
         defp_params,
         info,
         module,
         env,
         wc
       ) do
    maybe_build_assertion_defp(
      wc.post_fn_name,
      defp_params,
      postcondition_extra_params(wc.old_pairs),
      postconditions,
      info,
      module,
      env,
      wc.post_mode
    )
  end

  defp build_post_defp(%__MODULE__{} = af, postconditions, defp_params, info, module, env, wc) do
    body =
      Assertion.post_strengthen_body(
        postconditions,
        af.post_strengthen_assertions,
        wc.strengthen_prelude,
        info,
        module
      )

    params = defp_params ++ postcondition_extra_params(wc.old_pairs)
    build_lifted_defp_with_body(wc.post_fn_name, params, body, env)
  end

  # Emits the `@dialyzer {:nowarn_function, ...}` + `defp name(params) do body end` pair shared by
  # the refined assertion defps (the ordinary path inlines the same shape in
  # `maybe_build_assertion_defp/8`). See that function for why the nowarn attribute is needed.
  defp build_lifted_defp_with_body(name, params, body, env) do
    arity = length(params)

    quote file: env.file, line: env.line do
      @dialyzer {:nowarn_function, [{unquote(name), unquote(arity)}]}
      defp unquote(name)(unquote_splicing(params)) do
        unquote(body)
      end
    end
  end

  # Builds the `impl_name = canonical_name` assignment preludes for a refining function (#16). The
  # lifted assertion defps take the inherited contract's *canonical* (callback) names as their
  # parameters, but `@pre_weaken`/`@post_strengthen` expressions reference the implementation's OWN
  # parameter names; for each position a refinement references, bind the impl name to the canonical
  # value so the refinement evaluates correctly. Returns `{weaken_prelude, strengthen_prelude}` —
  # assignment-AST lists spliced into the precondition and postcondition defps; both empty for a
  # non-refining function.
  defp refinement_preludes(%__MODULE__{} = af, canonical_names, env, function_info) do
    if af.pre_weaken_assertions == [] and af.post_strengthen_assertions == [] do
      {[], []}
    else
      all = af.pre_weaken_assertions ++ af.post_strengthen_assertions
      referenced_any = Clauses.referenced_param_names(all, af.clauses)

      {:ok, impl_names} =
        Clauses.assert_clauses_agree!(af.clauses, env, function_info, referenced_any)

      canonical_set = MapSet.new(canonical_names)

      {
        group_prelude(
          af.pre_weaken_assertions,
          af,
          impl_names,
          canonical_names,
          canonical_set,
          env
        ),
        group_prelude(
          af.post_strengthen_assertions,
          af,
          impl_names,
          canonical_names,
          canonical_set,
          env
        )
      }
    end
  end

  defp group_prelude([], _af, _impl_names, _canonical_names, _canonical_set, _env), do: []

  defp group_prelude(group, af, impl_names, canonical_names, canonical_set, env) do
    referenced = Clauses.referenced_param_names(group, af.clauses)

    bindings =
      impl_names
      |> Enum.zip(canonical_names)
      |> Enum.filter(fn {impl_name, _canonical} -> MapSet.member?(referenced, impl_name) end)
      |> Enum.reject(fn {impl_name, canonical} -> impl_name == canonical end)

    Enum.each(bindings, fn {impl_name, _canonical} ->
      if MapSet.member?(canonical_set, impl_name) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: refinement_name_collision_message(impl_name, {af.fun, af.arity})
      end
    end)

    for {impl_name, canonical} <- bindings do
      quote do: unquote(Macro.var(impl_name, nil)) = unquote(Macro.var(canonical, nil))
    end
  end

  defp refinement_name_collision_message(impl_name, {fun, arity}) do
    "Bond: the refinement on `#{fun}/#{arity}` uses the parameter name `#{impl_name}`, which is " <>
      "also an argument name of the inherited contract at a different position. Rename the " <>
      "implementation's parameter so refinement (`@pre_weaken`/`@post_strengthen`) bindings do " <>
      "not shadow the inherited contract's arguments."
  end

  # The `:purge` mode is intercepted by `build_pre_defp/6` / `build_post_defp/7` before reaching
  # here, so this builder is only ever called for an emitted kind.
  defp maybe_build_assertion_defp(
         name,
         call_params,
         extra_params,
         assertions,
         function_info,
         function_module,
         env,
         _mode
       ) do
    body = Assertion.assertions_body(assertions, function_info, function_module)
    params = call_params ++ extra_params
    arity = length(params)

    quote file: env.file, line: env.line do
      # Suppress Dialyzer warnings for this generated assertion defp rather than widening
      # the wrapper's argument types through `Bond.Predicates.__opaque__/1` at the call
      # boundary. A `@pre`/`@post` that duplicates a typespec-implied guard (e.g.
      # `is_binary(x)` on a `binary()` argument) makes the `false ->` branch of the
      # assertion's `and/2` expansion appear dead; nowarn silences that pattern_match
      # warning at zero runtime cost. Because the assertion result is `term()`-checked in
      # `Bond.Runtime.Eval.check_assertion/3`, little real Dialyzer coverage is lost.
      @dialyzer {:nowarn_function, [{unquote(name), unquote(arity)}]}
      defp unquote(name)(unquote_splicing(params)) do
        unquote(body)
      end
    end
  end
end
