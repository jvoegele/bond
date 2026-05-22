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
  alias Bond.Compiler.FunctionDefinition
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
    has_preconditions?(annotated_function) or has_postconditions?(annotated_function)
  end

  @typedoc """
  Result of analysing a function head for an invariant-bearing argument.

    * `{:ok, var_name}` — the function pattern-matches `%__MODULE__{} = name` (in either
      order) or has an `is_struct(name, __MODULE__)` guard. `name` is the bound variable
      that the pre-invariant should check.
    * `{:warn, :unbound_destructure}` — the function destructures `%__MODULE__{...}` but
      doesn't bind the whole struct to a variable. Pre-invariant check is skipped; callers
      should emit a compile-time warning suggesting `%__MODULE__{...} = name`.
    * `:none` — neither pattern nor guard references `%__MODULE__{}`. Skip silently.
  """
  @type struct_arg_result :: {:ok, atom()} | {:warn, atom()} | :none

  @doc """
  Inspects a function's parameter list and guards for a binding to this module's struct.

  Only matches the `%__MODULE__{}` form. Fully-qualified module patterns (`%MyMod{}`) and
  aliased forms (`%alias_for_mod{}`) are not recognised in 0.13.0 — users who want
  invariant pre-checks should use `__MODULE__` idiomatically. See the module docs for the
  recognition table.
  """
  @spec find_struct_arg([Macro.t()], [Macro.t()]) :: struct_arg_result()
  def find_struct_arg(params, guards) when is_list(params) and is_list(guards) do
    cond do
      name = bound_struct_param(params) -> {:ok, name}
      name = is_struct_guard_var(guards) -> {:ok, name}
      unbound_struct_param?(params) -> {:warn, :unbound_destructure}
      true -> :none
    end
  end

  # Matches `%__MODULE__{} = name` and `name = %__MODULE__{}` (either order of `=` operands).
  defp bound_struct_param(params) do
    Enum.find_value(params, fn
      {:=, _, [{:%, _, [{:__MODULE__, _, _}, _]}, {var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        var

      {:=, _, [{var, _, ctx}, {:%, _, [{:__MODULE__, _, _}, _]}]}
      when is_atom(var) and is_atom(ctx) ->
        var

      _ ->
        nil
    end)
  end

  # Matches `%__MODULE__{...}` without an enclosing `= name` binding.
  defp unbound_struct_param?(params) do
    Enum.any?(params, fn
      {:%, _, [{:__MODULE__, _, _}, _]} -> true
      _ -> false
    end)
  end

  # Walks guard ASTs for `is_struct(var, __MODULE__)`. Handles `and`-combined guards
  # (both branches reachable). `or`-combined guards are not unwrapped — only the first
  # branch would carry the struct check, and the runtime might enter via the other branch.
  defp is_struct_guard_var(guards) do
    Enum.find_value(guards, &extract_is_struct_var/1)
  end

  defp extract_is_struct_var({:is_struct, _, [{var, _, ctx}, {:__MODULE__, _, _}]})
       when is_atom(var) and is_atom(ctx) do
    var
  end

  defp extract_is_struct_var({:and, _, [left, right]}) do
    extract_is_struct_var(left) || extract_is_struct_var(right)
  end

  defp extract_is_struct_var(_), do: nil

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
          required(:postconditions) => mode()
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

    if pre_mode != :purge or post_mode != :purge do
      build_contract_override(annotated_function, pre_mode, post_mode)
    end
  end

  # A kind is effectively purged if either the user purged it OR the function has no
  # assertions of that kind — there's nothing to evaluate or document either way.
  defp resolve_mode(:purge, _has_assertions?), do: :purge
  defp resolve_mode(_value, false), do: :purge
  defp resolve_mode(value, true) when value in [true, false], do: value

  defp build_contract_override(
         %__MODULE__{kind: kind, fun: fun, arity: arity} = annotated_function,
         pre_mode,
         post_mode
       ) do
    first_clause = List.first(annotated_function.clauses)
    function_info = {fun, arity}

    # If any params in the original use default-arg syntax (`trap_door \\ nil`), strip the
    # default so the override is a plain arity-N def with no default args. Elixir's
    # auto-generated forwarding clauses for the original still dispatch by name+arity, so
    # they end up calling our override.
    call_params = strip_default_args(first_clause.params)

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

    doc_asts = doc_clauses(annotated_function, first_clause.env, pre_mode, post_mode)

    body_stmts =
      build_override_body(
        call_params,
        pre_fn_name,
        post_fn_name,
        old_assignments,
        old_pairs,
        pre_mode,
        post_mode
      )

    assertion_defs =
      Enum.reject(
        [
          maybe_build_assertion_defp(
            pre_fn_name,
            call_params,
            [],
            annotated_function.preconditions,
            function_info,
            first_clause.env,
            pre_mode
          ),
          maybe_build_assertion_defp(
            post_fn_name,
            call_params,
            postcondition_extra_params(old_pairs),
            postconditions,
            function_info,
            first_clause.env,
            post_mode
          )
        ],
        &is_nil/1
      )

    quote file: first_clause.env.file, line: first_clause.env.line do
      defoverridable([{unquote(fun), unquote(arity)}])

      unquote_splicing(doc_asts)

      unquote(kind)(unquote(fun)(unquote_splicing(call_params))) do
        (unquote_splicing(body_stmts))
      end

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

  defp build_override_body(
         call_params,
         pre_fn_name,
         post_fn_name,
         old_assignments,
         old_pairs,
         pre_mode,
         post_mode
       ) do
    pre_stmts = pre_eval_stmts(call_params, pre_fn_name, pre_mode)
    super_call = quote(do: var!(result) = super(unquote_splicing(call_params)))
    post_stmts = post_eval_stmts(call_params, post_fn_name, old_pairs, post_mode)
    return_stmt = quote(do: var!(result))

    pre_stmts ++ old_assignments ++ [super_call] ++ post_stmts ++ [return_stmt]
  end

  defp pre_eval_stmts(_call_params, _name, :purge), do: []

  defp pre_eval_stmts(call_params, name, mode) do
    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(:preconditions, unquote(mode)) do
          Bond.Runtime.Eval.evaluate_preconditions(fn ->
            unquote(name)(unquote_splicing(call_params))
          end)
        end
      end
    ]
  end

  defp post_eval_stmts(_call_params, _name, _old_pairs, :purge), do: []

  defp post_eval_stmts(call_params, name, old_pairs, mode) do
    old_args = for {var, _expression} <- old_pairs, do: quote(do: var!(unquote(var)))
    args = call_params ++ [quote(do: var!(result)) | old_args]

    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(:postconditions, unquote(mode)) do
          Bond.Runtime.Eval.evaluate_postconditions(fn ->
            unquote(name)(unquote_splicing(args))
          end)
        end
      end
    ]
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

  defp strip_default_args(params) do
    Enum.map(params, fn
      {:\\, _meta, [param, _default]} -> param
      other -> other
    end)
  end

  defp doc_clauses(
         %__MODULE__{doc_attributes: doc_attributes} = annotated_function,
         env,
         pre_mode,
         post_mode
       ) do
    contract_docs = build_contract_docs(annotated_function, pre_mode, post_mode)

    has_string_doc? = Enum.any?(doc_attributes, fn {_meta, value} -> is_binary(value) end)

    augmented =
      cond do
        has_string_doc? ->
          Enum.map(doc_attributes, fn
            {meta, value} when is_binary(value) and contract_docs != "" ->
              {meta, value <> "\n\n" <> contract_docs}

            other ->
              other
          end)

        contract_docs != "" ->
          # No user-supplied string doc; synthesise one containing just the contract docs so
          # the contracts always appear in generated documentation.
          [{[line: env.line], contract_docs} | doc_attributes]

        true ->
          doc_attributes
      end

    for {meta, value} <- augmented do
      line = Keyword.get(meta, :line, env.line)

      quote do
        Module.put_attribute(__MODULE__, :doc, {unquote(line), unquote(Macro.escape(value))})
      end
    end
  end

  defp build_contract_docs(
         %__MODULE__{preconditions: preconditions, postconditions: postconditions},
         pre_mode,
         post_mode
       ) do
    precondition_docs =
      if pre_mode != :purge,
        do: generate_assertion_docs(preconditions, header: "#### Preconditions"),
        else: []

    postcondition_docs =
      if post_mode != :purge,
        do: generate_assertion_docs(postconditions, header: "#### Postconditions"),
        else: []

    contract_iodata =
      case {Enum.empty?(precondition_docs), Enum.empty?(postcondition_docs)} do
        {true, true} -> []
        {true, false} -> postcondition_docs
        {false, true} -> precondition_docs
        {false, false} -> [precondition_docs, "\n\n", postcondition_docs]
      end

    IO.iodata_to_binary(contract_iodata)
  end

  defp generate_assertion_docs([], _opts), do: []

  defp generate_assertion_docs(assertions, opts) do
    header = if header = opts[:header], do: header <> "\n\n", else: ""

    assertions
    |> Enum.reduce([], fn
      %{label: nil, code: code}, acc ->
        [code | acc]

      assertion, acc ->
        label = assertion.label |> inspect() |> String.trim_leading(":")
        [[label, ": ", assertion.code] | acc]
    end)
    |> Enum.reverse()
    |> List.insert_at(0, header)
    |> Enum.intersperse("\n    ")
  end
end
