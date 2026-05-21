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
            doc_attributes: []

  @type t :: %__MODULE__{
          kind: :def | :defp | nil,
          module: module() | nil,
          fun: atom() | nil,
          arity: non_neg_integer() | nil,
          clauses: [__MODULE__.Clause.t()],
          preconditions: [Bond.Compiler.Assertion.t()],
          postconditions: [Bond.Compiler.Assertion.t()],
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

  @typedoc """
  Configuration controlling which kinds of contracts are emitted by `apply_contract/2`.

  Used by `Bond.Compiler.__before_compile__/1` to honour the `:bond` application config keys
  `:preconditions` and `:postconditions`. Either flag set to `false` causes the corresponding
  evaluation to be omitted from the override clause and the corresponding section to be
  omitted from the auto-generated documentation.
  """
  @type contract_config :: %{
          required(:preconditions) => boolean(),
          required(:postconditions) => boolean()
        }

  @doc """
  Returns a quoted expression that wraps the annotated function with its contract, or `nil`
  when nothing needs to be emitted.

  The default `config` enables both preconditions and postconditions, matching pre-0.10.0
  behaviour. Setting either flag to `false` suppresses the corresponding piece of the
  override:

    * `preconditions: false` — the override clause does not build or call the preconditions
      function, and the `#### Preconditions` section is omitted from the auto-generated docs.
    * `postconditions: false` — the override clause does not build or call the postconditions
      function, and the `#### Postconditions` section is omitted from the auto-generated docs.
    * Both `false` (or the function has neither pre- nor postconditions) — returns `nil`. The
      caller should filter `nil`s out and not emit anything for this function. The user's
      original `def`/`defp` runs as written, with no docs added by Bond (Bond intercepts
      `@doc` and only emits it back via the override path).

  When an override clause IS emitted, the expression contains three things:

    1. A `defoverridable` declaration making the function overridable.
    2. Zero or more `@doc` clauses re-emitting any `@doc` attributes the user attached to the
       function. Any string-valued doc has the auto-generated "Preconditions" and
       "Postconditions" sections appended (filtered by `config`). If the function has
       contracts but no user-supplied string `@doc`, a synthetic `@doc` containing just the
       contract documentation is added.
    3. A single override clause for the function that:

         * builds a fn evaluating the preconditions and calls
           `Bond.Runtime.Eval.evaluate_preconditions/1` (skipped if
           `preconditions: false`),
         * resolves any `old(...)` expressions found in the postconditions into local bindings,
         * delegates to the original implementation via `super(...)`, capturing the result,
         * builds a fn evaluating the postconditions and calls
           `Bond.Runtime.Eval.evaluate_postconditions/1` (skipped if
           `postconditions: false`),
         * returns the captured result.

  The override clause uses the parameter names from the function's first clause. For
  multi-clause functions Elixir's normal pattern matching applies inside `super(...)`, so a
  single wrapper clause covers every original clause.
  """
  @spec apply_contract(t(), contract_config()) :: Macro.t() | nil
  def apply_contract(annotated_function, config \\ %{preconditions: true, postconditions: true})

  def apply_contract(%__MODULE__{} = annotated_function, config) do
    emit_pre? = Map.fetch!(config, :preconditions) and has_preconditions?(annotated_function)
    emit_post? = Map.fetch!(config, :postconditions) and has_postconditions?(annotated_function)

    if emit_pre? or emit_post? do
      build_contract_override(annotated_function, emit_pre?, emit_post?)
    end
  end

  defp build_contract_override(
         %__MODULE__{kind: kind, fun: fun, arity: arity} = annotated_function,
         emit_pre?,
         emit_post?
       ) do
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
      if emit_pre? do
        Assertion.create_assertions_function(annotated_function.preconditions, function_info)
      end

    postconditions_fun_ast =
      if emit_post? do
        Assertion.create_assertions_function(postconditions, function_info)
      end

    doc_asts = doc_clauses(annotated_function, first_clause.env, emit_pre?, emit_post?)

    body_stmts =
      build_override_body(
        call_params,
        preconditions_fun_ast,
        postconditions_fun_ast,
        old_resolved_ast,
        emit_pre?,
        emit_post?
      )

    quote file: first_clause.env.file, line: first_clause.env.line do
      defoverridable([{unquote(fun), unquote(arity)}])

      unquote_splicing(doc_asts)

      unquote(kind)(unquote(fun)(unquote_splicing(call_params))) do
        (unquote_splicing(body_stmts))
      end
    end
  end

  defp build_override_body(
         call_params,
         preconditions_fun_ast,
         postconditions_fun_ast,
         old_resolved_ast,
         emit_pre?,
         emit_post?
       ) do
    pre_stmts =
      if emit_pre? do
        [
          quote(do: preconditions_fun = unquote(preconditions_fun_ast)),
          quote(do: Bond.Runtime.Eval.evaluate_preconditions(preconditions_fun))
        ]
      else
        []
      end

    super_call = quote(do: var!(result) = super(unquote_splicing(call_params)))

    post_stmts =
      if emit_post? do
        [
          quote(do: postconditions_fun = unquote(postconditions_fun_ast)),
          quote(do: Bond.Runtime.Eval.evaluate_postconditions(postconditions_fun))
        ]
      else
        []
      end

    return_stmt = quote(do: var!(result))

    pre_stmts ++ [old_resolved_ast, super_call] ++ post_stmts ++ [return_stmt]
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
         emit_pre?,
         emit_post?
       ) do
    contract_docs = build_contract_docs(annotated_function, emit_pre?, emit_post?)

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
         emit_pre?,
         emit_post?
       ) do
    precondition_docs =
      if emit_pre?,
        do: generate_assertion_docs(preconditions, header: "#### Preconditions"),
        else: []

    postcondition_docs =
      if emit_post?,
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
