defmodule Bond.Compiler.AnnotatedFunction do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for attaching contracts (i.e. preconditions and/or postconditions) to a
  function.

  The struct in this module represents all clauses of a function. If multiple clauses for a
  function are defined (with `def/2` or `defp/2`), the `:clauses` field of the struct will contain
  one `Bond.Compiler.AnnotatedFunction.Clause` struct for each clause.

  The `:preconditions`, `:postconditions`, and `:doc_attributes` fields apply to all clauses of a
  function.
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
            doc_attributes: []

  defmodule Clause do
    @moduledoc internal: true
    @moduledoc """
    Struct to represent an individual clause of a function.
    """

    alias Bond.Compiler.FunctionDefinition

    defstruct [:env, :params, :guards, :body]

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

  def has_doc_attributes?(%__MODULE__{doc_attributes: doc_attributes}),
    do: not Enum.empty?(doc_attributes)

  def override?(%__MODULE__{} = annotated_function) do
    has_preconditions?(annotated_function) or has_postconditions?(annotated_function)
  end

  @doc """
  Returns a quoted expression that wraps the annotated function with its contract.

  The expression contains three things:

    1. A `defoverridable` declaration making the function overridable.
    2. Zero or more `@doc` clauses re-emitting any `@doc` attributes the user attached to the
       function. Any string-valued doc has the auto-generated "Preconditions" and
       "Postconditions" sections appended. If the function has contracts but no user-supplied
       string `@doc`, a synthetic `@doc` containing just the contract documentation is added.
    3. A single override clause for the function that:

         * builds a fn evaluating the preconditions and calls
           `Bond.Runtime.Eval.evaluate_preconditions/1`,
         * resolves any `old(...)` expressions found in the postconditions into local bindings,
         * delegates to the original implementation via `super(...)`, capturing the result,
         * builds a fn evaluating the postconditions and calls
           `Bond.Runtime.Eval.evaluate_postconditions/1`,
         * returns the captured result.

  The override clause uses the parameter names from the function's first clause. For
  multi-clause functions Elixir's normal pattern matching applies inside `super(...)`, so a
  single wrapper clause covers every original clause.
  """
  def apply_contract(%__MODULE__{kind: kind, fun: fun, arity: arity} = annotated_function) do
    first_clause = List.first(annotated_function.clauses)
    function_info = {fun, arity}

    # If any params in the original use default-arg syntax (`trap_door \\ nil`), strip the
    # default so the override is a plain arity-N def with no default args. Elixir's
    # auto-generated forwarding clauses for the original still dispatch by name+arity, so
    # they end up calling our override.
    call_params = strip_default_args(first_clause.params)

    {postconditions, old_context} = OldExpression.precompile(annotated_function.postconditions)
    old_resolved_ast = OldExpression.resolve(old_context)

    preconditions_fun_ast =
      Assertion.create_assertions_function(annotated_function.preconditions, function_info)

    postconditions_fun_ast =
      Assertion.create_assertions_function(postconditions, function_info)

    doc_asts = doc_clauses(annotated_function, first_clause.env)

    quote file: first_clause.env.file, line: first_clause.env.line do
      defoverridable([{unquote(fun), unquote(arity)}])

      unquote_splicing(doc_asts)

      unquote(kind)(unquote(fun)(unquote_splicing(call_params))) do
        preconditions_fun = unquote(preconditions_fun_ast)
        Bond.Runtime.Eval.evaluate_preconditions(preconditions_fun)

        unquote(old_resolved_ast)

        var!(result) = super(unquote_splicing(call_params))

        postconditions_fun = unquote(postconditions_fun_ast)
        Bond.Runtime.Eval.evaluate_postconditions(postconditions_fun)

        var!(result)
      end
    end
  end

  defp strip_default_args(params) do
    Enum.map(params, fn
      {:\\, _meta, [param, _default]} -> param
      other -> other
    end)
  end

  defp doc_clauses(%__MODULE__{doc_attributes: doc_attributes} = annotated_function, env) do
    contract_docs = build_contract_docs(annotated_function)

    has_string_doc? =
      Enum.any?(doc_attributes, fn {_meta, value} -> is_binary(value) end)

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

  defp build_contract_docs(%__MODULE__{
         preconditions: preconditions,
         postconditions: postconditions
       }) do
    precondition_docs = generate_assertion_docs(preconditions, header: "#### Preconditions")
    postcondition_docs = generate_assertion_docs(postconditions, header: "#### Postconditions")

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
