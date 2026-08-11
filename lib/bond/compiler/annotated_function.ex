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
  alias Bond.Compiler.Availability
  alias Bond.Compiler.PurgedAttributes
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
            # expressions reference the abstraction's canonical argument names (the same names the
            # inherited contract uses), so they fold against the inherited assertions in
            # `preconditions` / `postconditions` without any name rebinding.
            pre_weaken_assertions: [],
            post_strengthen_assertions: [],
            # Named contracts applied to this function via `@apply_contract` (#35), as a list of
            # `%{ref: ref, env: env}` where `ref` is `{:local, name}` or `{:remote, module, name}`.
            # Captured by the FSM and resolved into inherited-style contracts at
            # `Bond.Compiler.__before_compile__/1` time, keyed by this function's `{fun, arity}`.
            applied_contracts: [],
            # Set when a zero-argument `defcontract name()` is applied via `@apply_contract`.
            # The contract carries no canonical arg names (it is arity-agnostic), so the wrapper
            # and `super` call use the function's own parameter names derived from its clauses.
            # The lifted precondition/postcondition defp still receives those params in the call,
            # but they are underscore-prefixed in the defp head to suppress unused-variable
            # warnings — the contract expressions only reference `result`.
            result_only_contract: false

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
          post_strengthen_assertions: [Bond.Compiler.Assertion.t()],
          applied_contracts: [%{ref: tuple(), env: Macro.Env.t()}],
          result_only_contract: boolean()
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

  @doc """
  Returns the function's positional argument names — the canonical names its contract expressions
  reference, one per argument in declaration order.

  For an inherited contract these are the callback's canonical names (`canonical_names_override`);
  otherwise they are the names negotiated across the clauses by `resolve_canonical_names/2`
  (raising the same multi-clause name-disagreement `CompileError` that contract compilation does).

  Used by boundary extraction (#36, `Bond.Compiler.Boundaries`) to map a precondition such as
  `amount >= 0` to the positional index of `amount`, since those expressions reference exactly
  these names.
  """
  @spec arg_names(t()) :: [atom()]
  def arg_names(%__MODULE__{fun: fun, arity: arity} = annotated_function) do
    resolve_canonical_names(annotated_function, {fun, arity})
  end

  def add_clause(
        %__MODULE__{module: module, fun: function, arity: arity, clauses: clauses} = function_def,
        %FunctionDefinition{module: module, fun: function, arity: arity} = clause_def
      ) do
    %{function_def | clauses: clauses ++ [Clause.new(clause_def)]}
  end

  def put_preconditions(%__MODULE__{} = annotated_function, preconditions)
      when is_list(preconditions),
      do: append_assertions(annotated_function, :preconditions, preconditions)

  def put_postconditions(%__MODULE__{} = annotated_function, postconditions)
      when is_list(postconditions),
      do: append_assertions(annotated_function, :postconditions, postconditions)

  def put_invariants(%__MODULE__{} = annotated_function, invariants) when is_list(invariants),
    do: append_assertions(annotated_function, :invariants, invariants)

  # Appends to one of the assertion lists, first asserting that every element is the expected
  # struct — any `Assertion` for preconditions/postconditions, an `Assertion` of `kind:
  # :invariant` for invariants. The resulting `MatchError` means the compiler wired one kind's
  # list into another kind's field, which is a Bond bug rather than anything the user wrote.
  defp append_assertions(annotated_function, :invariants = field, assertions) do
    Enum.each(assertions, fn %Assertion{kind: :invariant} -> :ok end)
    Map.update!(annotated_function, field, &(&1 ++ assertions))
  end

  defp append_assertions(annotated_function, field, assertions) do
    Enum.each(assertions, fn %Assertion{} -> :ok end)
    Map.update!(annotated_function, field, &(&1 ++ assertions))
  end

  def put_doc_attributes(
        %__MODULE__{doc_attributes: existing_doc_attributes} = annotated_function,
        doc_attributes
      )
      when is_list(doc_attributes) do
    %{annotated_function | doc_attributes: existing_doc_attributes ++ doc_attributes}
  end

  @doc """
  Records the named contracts (`@apply_contract`) that precede this function, to be resolved and
  merged at `__before_compile__` time. See the `:applied_contracts` field.
  """
  def put_applied_contracts(
        %__MODULE__{applied_contracts: existing} = annotated_function,
        applied_contracts
      )
      when is_list(applied_contracts) do
    %{annotated_function | applied_contracts: existing ++ applied_contracts}
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
  Marks a zero-argument named contract (`defcontract name()`) applied to this function.

  The contract carries no canonical argument names — it is arity-agnostic and only constrains
  `result`. The wrapper and `super` call use the function's own parameter names (derived
  normally from its clauses); `canonical_names_override` is left nil. The lifted defp still
  receives those params but they are underscore-prefixed in the head to suppress unused-variable
  warnings, since the contract expressions reference only `result`.
  """
  def put_result_only_contract(%__MODULE__{} = annotated_function) do
    %{annotated_function | result_only_contract: true}
  end

  @doc """
  Replaces the precondition/postcondition lists outright (vs the appending `put_*` setters).

  Used by `Bond.Compiler.ContractMerge.merge_inherited_contract/2` when folding a refinement: the impl's own
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
  the abstraction's canonical argument names and fold against the inherited contract at codegen.
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

  @doc """
  Whether `apply_contract/2` will emit a lifted precondition defp for this function under `config`
  — i.e. the precondition mode resolves to something other than `:purge`.

  This is the single source of truth (it routes through the same `resolve_mode/2` `apply_contract/2`
  uses) for deciding which functions get a `__bond_precondition__/3` shim clause (#36): the shim
  delegates to the lifted defp, so it may only be emitted when that defp actually exists.
  """
  @spec emits_preconditions?(t(), contract_config()) :: boolean()
  def emits_preconditions?(%__MODULE__{} = annotated_function, config) do
    resolve_mode(
      Map.fetch!(config, :preconditions),
      has_preconditions?(annotated_function) or has_pre_weaken?(annotated_function)
    ) != :purge
  end

  @doc """
  The name of the lifted precondition defp `apply_contract/2` emits for this function — the
  private `__bond_preconditions__<fun>__<arity>` that the `__bond_precondition__/3` shim delegates
  to (#36). Only meaningful when `emits_preconditions?/2` is true.
  """
  @spec precondition_fn_name(t()) :: atom()
  def precondition_fn_name(%__MODULE__{fun: fun, arity: arity}) do
    lifted_fn_name(:preconditions, fun, arity)
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
          optional(:invariants) => mode(),
          # Whether Bond owns `@` in this module, and so whether it may emit documentation at
          # all (#71). Not a contract kind and not part of the pre ≤ post ≤ invariant chain;
          # it rides along on the config map because that is what is already threaded from
          # `Bond.Compiler.__before_compile__/1` down into codegen.
          optional(:at_annotations) => boolean(),
          optional(:warn_skipped_invariants) => boolean(),
          optional(:warn_unavailable_preconditions) => boolean(),
          # The using module's private functions, from `Module.definitions_in/2` at
          # `__before_compile__`. Rides along like `:aliases` and `:at_annotations`,
          # because this map is what is already threaded down into codegen; used by the
          # Precondition Availability check (#92).
          optional(:private_defs) => MapSet.t(),
          # The using module's alias table, as captured from `env.aliases` at
          # `__before_compile__`. Rides along for the same reason `:at_annotations` does:
          # invariant head detection needs it to resolve a struct named through an alias
          # (#93), and this map is what is already threaded down into codegen.
          optional(:aliases) => keyword()
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
    maybe_warn_unavailable_preconditions(annotated_function, pre_mode, config)
    consume_purged_attributes(annotated_function, pre_mode, post_mode, inv_mode)

    if pre_mode != :purge or post_mode != :purge or inv_mode != :purge do
      # Whether Bond owns `@` — and so documentation — in this module. Supplied by
      # `Bond.Compiler.__before_compile__/1` from `@__bond_at_annotations__`; defaults to `true`
      # for callers that build a config map directly.
      owns_docs? = Map.get(config, :at_annotations, true)

      build_contract_override(
        annotated_function,
        pre_mode,
        post_mode,
        inv_mode,
        owns_docs?,
        Map.get(config, :aliases, [])
      )
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
  #     return, AND no clause mentions the struct anywhere at all (#80)
  #
  # The second condition is the one that keeps this honest. The post-invariant
  # check is emitted unconditionally and matches the return value's shape at
  # runtime, so a function returning the struct by any means has its invariants
  # checked on exit — even when the static heuristic cannot see it. Warning on
  # the strength of the heuristic alone fired on functions that were demonstrably
  # covered. See `Invariants.any_clause_mentions_struct?/2`.
  defp maybe_warn_skipped_invariants(
         %__MODULE__{kind: :def, invariants: [_ | _], module: struct_module} = annotated_function,
         inv_mode,
         config
       )
       when inv_mode != :purge do
    warn? = resolve_warn(annotated_function.clauses, config, :warn_skipped_invariants)

    if warn? and
         not Invariants.any_clause_checks_invariants?(
           annotated_function.clauses,
           struct_module,
           Map.get(config, :aliases, [])
         ) and
         not Invariants.any_clause_mentions_struct?(
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

  # A purged contract is discarded before its AST reaches the BEAM, taking with it the
  # only read of any module attribute it mentioned (#79). Read those attributes here so
  # the constant does not warn as unused in the purging build.
  defp consume_purged_attributes(
         %__MODULE__{module: module} = annotated_function,
         pre_mode,
         post_mode,
         inv_mode
       ) do
    purged =
      [
        {pre_mode, annotated_function.preconditions},
        {post_mode, annotated_function.postconditions},
        {inv_mode, annotated_function.invariants}
      ]
      |> Enum.filter(fn {mode, _assertions} -> mode == :purge end)
      |> Enum.flat_map(fn {_mode, assertions} -> assertions end)
      |> Enum.map(& &1.expression)

    PurgedAttributes.consume(module, purged)
  end

  # Meyer's Precondition Availability rule (#92): a public function's precondition must
  # not be stated in terms its callers cannot reach. Only preconditions — postconditions
  # are exempt by the same source, being the function's promise rather than the caller's
  # obligation — and only on `def`, since a `defp`'s only clients are in this module.
  #
  # Skipped when preconditions are purged: there is no contract for a caller to satisfy.
  defp maybe_warn_unavailable_preconditions(
         %__MODULE__{kind: :def, preconditions: [_ | _]} = annotated_function,
         pre_mode,
         config
       )
       when pre_mode != :purge do
    private_defs = Map.get(config, :private_defs, MapSet.new())

    if resolve_warn(annotated_function.clauses, config, :warn_unavailable_preconditions) and
         MapSet.size(private_defs) > 0 do
      calls =
        annotated_function.preconditions
        |> Enum.flat_map(&Availability.private_calls(&1, private_defs))
        |> Enum.uniq()

      if calls != [] do
        first_clause = List.first(annotated_function.clauses)

        IO.warn(
          Availability.warning_message(
            annotated_function.module,
            annotated_function.fun,
            annotated_function.arity,
            calls
          ),
          first_clause.env
        )
      end
    end
  end

  defp maybe_warn_unavailable_preconditions(_annotated_function, _pre_mode, _config), do: :ok

  # Resolves the final warn-or-not decision for one of the per-function warning flags. The
  # per-function `@bond_warn_*` override — the first clause that set one wins — takes precedence
  # over the module/global config value; with no override, the resolved config decides.
  #
  # `flag` names both the clause field holding the override (`<flag>_override`) and the config
  # key, which are deliberately kept in step.
  #
  # Uses an explicit nil search rather than `Enum.find_value/2` because the override is a
  # tri-state (nil | true | false) and `find_value` treats `false` the same as nil — which would
  # silently drop legitimate `false` overrides.
  defp resolve_warn(clauses, config, flag) do
    override_field = :"#{flag}_override"

    per_function_override =
      clauses
      |> Enum.map(&Map.fetch!(&1, override_field))
      |> Enum.find(&(&1 != nil))

    case per_function_override do
      nil -> Map.get(config, flag, true)
      bool when is_boolean(bool) -> bool
    end
  end

  defp skipped_invariants_warning_message(%__MODULE__{
         module: module,
         fun: fun,
         arity: arity
       }) do
    "public function `#{fun}/#{arity}` in invariant-declaring module " <>
      "`#{inspect(module)}` never mentions the struct: no clause matches " <>
      "`%#{inspect(module)}{}` in its head or builds one in its body, so the " <>
      "entry check is skipped and invariants are skipped here. (The exit check " <>
      "still fires if this function returns a `%#{inspect(module)}{}` at " <>
      "runtime.) If intentional, suppress with " <>
      "`@bond_warn_skipped_invariants false` (per function), " <>
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
         inv_mode,
         owns_docs?,
         aliases
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

    doc_asts = ContractDocs.doc_clauses(annotated_function, env, pre_mode, post_mode, owns_docs?)

    # Only meaningful alongside an emitted doc: it exists to let that doc override the one the
    # user's own `@doc` already set, without Elixir's "redefining @doc" warning.
    doc_head_ast =
      if doc_asts == [],
        do: [],
        else: ContractDocs.doc_override_head(annotated_function, canonical_names)

    wrapper_context = %{
      fun: fun,
      arity: arity,
      kind: kind,
      struct_module: struct_module,
      aliases: aliases,
      pre_mode: pre_mode,
      post_mode: post_mode,
      inv_mode: inv_mode,
      pre_fn_name: lifted_fn_name(:preconditions, fun, arity),
      post_fn_name: lifted_fn_name(:postconditions, fun, arity),
      inv_fn_name: lifted_fn_name(:invariants, fun, arity),
      old_pairs: OldExpression.pairs(old_context),
      old_assignments: OldExpression.resolve(old_context)
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

      unquote_splicing(doc_head_ast)

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
    referenced_names = referenced_param_names(annotated_function)

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

  # The parameter names this function's own contracts reference. Shared by canonical-name
  # resolution (which positions must agree across clauses) and by the single-clause lifted defp
  # head (which `= _name` bindings to rebind), so the two always answer from the same set.
  defp referenced_param_names(%__MODULE__{} = annotated_function) do
    Clauses.referenced_param_names(
      annotated_function.preconditions ++
        annotated_function.postconditions ++ annotated_function.invariants,
      annotated_function.clauses
    )
  end

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
  # Zero-argument result-only contract: the function's real canonical names are still passed to
  # the defp in the call (so the arity matches), but the defp head underscore-prefixes them all
  # to suppress "unused variable" warnings — the contract expressions reference only `result`.
  defp lifted_defp_params(
         %__MODULE__{result_only_contract: true},
         canonical_names,
         _first_clause
       ) do
    Enum.map(canonical_names, fn name -> Macro.var(:"_#{name}", nil) end)
  end

  defp lifted_defp_params(
         %__MODULE__{canonical_names_override: override},
         canonical_names,
         _first_clause
       )
       when not is_nil(override) do
    Enum.map(canonical_names, &Macro.var(&1, nil))
  end

  defp lifted_defp_params(
         %__MODULE__{clauses: [_single]} = annotated_function,
         _canonical_names,
         first_clause
       ) do
    # The user's pattern is reproduced so contracts can reference names destructured in the head,
    # but a top-level `= _name` binding has to be rebound to the canonical `name` the contract
    # expressions were written against — otherwise it is bound only under its underscored name and
    # the contract fails to compile (#64). See `Clauses.bind_referenced_canonical_names/2`.
    first_clause.params
    |> ClauseWrapper.strip_default_args()
    |> Clauses.bind_referenced_canonical_names(referenced_param_names(annotated_function))
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
    build_assertion_defp(wc.pre_fn_name, defp_params, af.preconditions, info, module, env)
  end

  defp build_pre_defp(%__MODULE__{} = af, defp_params, info, module, env, wc) do
    body = Assertion.pre_weaken_body(af.preconditions, af.pre_weaken_assertions, info, module)

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
    build_assertion_defp(
      wc.post_fn_name,
      defp_params ++ postcondition_extra_params(wc.old_pairs),
      postconditions,
      info,
      module,
      env
    )
  end

  defp build_post_defp(%__MODULE__{} = af, postconditions, defp_params, info, module, env, wc) do
    body =
      Assertion.post_strengthen_body(
        postconditions,
        af.post_strengthen_assertions,
        info,
        module
      )

    params = defp_params ++ postcondition_extra_params(wc.old_pairs)
    build_lifted_defp_with_body(wc.post_fn_name, params, body, env)
  end

  # Emits the `@dialyzer {:nowarn_function, …}` + `defp name(params) do body end` pair that every
  # lifted assertion defp is built from — the ordinary conjunctions and the refined
  # (`@pre_weaken` / `@post_strengthen`) forms alike.
  #
  # The nowarn suppresses Dialyzer warnings for this generated defp, rather than widening the
  # wrapper's argument types through `Bond.Predicates.__opaque__/1` at the call boundary. A
  # `@pre`/`@post` that duplicates a typespec-implied guard (e.g. `is_binary(x)` on a `binary()`
  # argument) makes the `false ->` branch of the assertion's `and/2` expansion appear dead; nowarn
  # silences that pattern_match warning at zero runtime cost. Because the assertion result is
  # `term()`-checked in `Bond.Runtime.Eval.check_assertion/3`, little real Dialyzer coverage is
  # lost.
  defp build_lifted_defp_with_body(name, params, body, env) do
    arity = length(params)

    quote file: env.file, line: env.line do
      @dialyzer {:nowarn_function, [{unquote(name), unquote(arity)}]}
      defp unquote(name)(unquote_splicing(params)) do
        unquote(body)
      end
    end
  end

  # The unrefined conjunction defp: every assertion of the kind, evaluated in order. The `:purge`
  # mode is intercepted by `build_pre_defp/6` / `build_post_defp/7` before reaching here, so this
  # is only ever called for an emitted kind.
  defp build_assertion_defp(name, params, assertions, function_info, function_module, env) do
    body = Assertion.assertions_body(assertions, function_info, function_module)
    build_lifted_defp_with_body(name, params, body, env)
  end
end
