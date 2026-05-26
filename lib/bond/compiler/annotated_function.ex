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

  defstruct kind: nil,
            module: nil,
            fun: nil,
            arity: nil,
            clauses: [],
            preconditions: [],
            postconditions: [],
            invariants: [],
            doc_attributes: []

  @type t :: %__MODULE__{
          kind: :def | :defp | nil,
          module: module() | nil,
          fun: atom() | nil,
          arity: non_neg_integer() | nil,
          clauses: [__MODULE__.Clause.t()],
          preconditions: [Bond.Compiler.Assertion.t()],
          postconditions: [Bond.Compiler.Assertion.t()],
          invariants: [Bond.Compiler.Assertion.t()],
          doc_attributes: [FunctionDefinition.doc_attribute()]
        }

  defmodule Clause do
    @moduledoc internal: true
    @moduledoc """
    Struct to represent an individual clause of a function.
    """

    alias Bond.Compiler.FunctionDefinition

    defstruct [:env, :params, :guards, :body]

    @type t :: %__MODULE__{
            env: Macro.Env.t() | nil,
            params: list() | nil,
            guards: list() | nil,
            body: keyword() | nil
          }

    def new(%FunctionDefinition{} = function_def) do
      struct(__MODULE__, Map.take(function_def, [:env, :params, :guards, :body]))
    end
  end

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

  def put_preconditions(
        %__MODULE__{preconditions: existing_preconditions} = annotated_function,
        preconditions
      )
      when is_list(preconditions) do
    # Check to make sure each element in the list is a `Bond.Assertion` struct.
    Enum.each(preconditions, fn %Assertion{} -> :ok end)

    %{annotated_function | preconditions: existing_preconditions ++ preconditions}
  end

  def put_postconditions(
        %__MODULE__{postconditions: existing_postconditions} = annotated_function,
        postconditions
      )
      when is_list(postconditions) do
    # Check to make sure each element in the list is a `Bond.Assertion` struct.
    Enum.each(postconditions, fn %Assertion{} -> :ok end)

    %{annotated_function | postconditions: existing_postconditions ++ postconditions}
  end

  def put_invariants(
        %__MODULE__{invariants: existing_invariants} = annotated_function,
        invariants
      )
      when is_list(invariants) do
    Enum.each(invariants, fn %Assertion{kind: :invariant} -> :ok end)

    %{annotated_function | invariants: existing_invariants ++ invariants}
  end

  def put_doc_attributes(
        %__MODULE__{doc_attributes: existing_doc_attributes} = annotated_function,
        doc_attributes
      )
      when is_list(doc_attributes) do
    %{annotated_function | doc_attributes: existing_doc_attributes ++ doc_attributes}
  end

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
    pre_mode =
      resolve_mode(Map.fetch!(config, :preconditions), has_preconditions?(annotated_function))

    post_mode =
      resolve_mode(Map.fetch!(config, :postconditions), has_postconditions?(annotated_function))

    inv_mode =
      Invariants.resolve_mode(
        Map.get(config, :invariants, true),
        annotated_function.kind,
        annotated_function.invariants
      )

    if pre_mode != :purge or post_mode != :purge or inv_mode != :purge do
      build_contract_override(annotated_function, pre_mode, post_mode, inv_mode)
    end
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
    function_info = {fun, arity}

    {:ok, canonical_names} =
      Clauses.assert_clauses_agree!(annotated_function.clauses, first_clause.env, function_info)

    {postconditions, old_context} =
      if post_mode != :purge do
        OldExpression.precompile(annotated_function.postconditions)
      else
        {[], %{}}
      end

    old_pairs = OldExpression.pairs(old_context)
    old_assignments = OldExpression.resolve(old_context)

    pre_fn_name = lifted_fn_name(:preconditions, fun, arity)
    post_fn_name = lifted_fn_name(:postconditions, fun, arity)
    inv_fn_name = lifted_fn_name(:invariants, fun, arity)

    doc_asts = ContractDocs.doc_clauses(annotated_function, first_clause.env, pre_mode, post_mode)

    wrapper_context = %{
      fun: fun,
      arity: arity,
      kind: kind,
      struct_module: struct_module,
      pre_mode: pre_mode,
      post_mode: post_mode,
      inv_mode: inv_mode,
      pre_fn_name: pre_fn_name,
      post_fn_name: post_fn_name,
      inv_fn_name: inv_fn_name,
      old_pairs: old_pairs,
      old_assignments: old_assignments
    }

    # Lifted-defp parameter strategy depends on whether the function has one
    # clause or many.
    #
    #   * Single-clause: lifted defp's head reproduces the user's pattern, so
    #     contracts can reference destructured names from the head (e.g.
    #     `current_count` from `%__MODULE__{count: current_count} = state`).
    #     The wrapper passes the canonical-named value; the defp re-binds via
    #     its pattern.
    #
    #   * Multi-clause: lifted defp's head is just the canonical names as bare
    #     vars. Contracts can only reference top-level names — they must apply
    #     uniformly to every clause, so destructured-name access from any
    #     individual clause is unavailable. Shape-dependent assertions use the
    #     `~>` implication operator.
    lifted_defp_params =
      case annotated_function.clauses do
        [_single] -> ClauseWrapper.strip_default_args(first_clause.params)
        _multi -> Enum.map(canonical_names, &Macro.var(&1, nil))
      end

    wrapper_clauses =
      Enum.map(annotated_function.clauses, fn clause ->
        ClauseWrapper.build_wrapper(clause, canonical_names, wrapper_context)
      end)

    assertion_defs =
      Enum.reject(
        [
          maybe_build_assertion_defp(
            pre_fn_name,
            lifted_defp_params,
            [],
            annotated_function.preconditions,
            function_info,
            first_clause.env,
            pre_mode
          ),
          maybe_build_assertion_defp(
            post_fn_name,
            lifted_defp_params,
            postcondition_extra_params(old_pairs),
            postconditions,
            function_info,
            first_clause.env,
            post_mode
          ),
          Invariants.build_lifted_defp(
            inv_fn_name,
            annotated_function.invariants,
            function_info,
            first_clause.env,
            inv_mode
          )
        ],
        &is_nil/1
      )

    quote file: first_clause.env.file, line: first_clause.env.line do
      defoverridable([{unquote(fun), unquote(arity)}])

      unquote_splicing(doc_asts)

      unquote_splicing(wrapper_clauses)

      unquote_splicing(assertion_defs)
    end
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

  defp maybe_build_assertion_defp(_name, _params, _extra, _assertions, _info, _env, :purge),
    do: nil

  defp maybe_build_assertion_defp(
         name,
         call_params,
         extra_params,
         assertions,
         function_info,
         env,
         _mode
       ) do
    body = Assertion.assertions_body(assertions, function_info)
    params = call_params ++ extra_params

    quote file: env.file, line: env.line do
      defp unquote(name)(unquote_splicing(params)) do
        unquote(body)
      end
    end
  end
end
