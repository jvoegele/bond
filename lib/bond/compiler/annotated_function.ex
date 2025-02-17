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
end
