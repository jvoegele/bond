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
end
