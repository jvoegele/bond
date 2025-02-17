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
end
