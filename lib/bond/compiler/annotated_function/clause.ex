defmodule Bond.Compiler.AnnotatedFunction.Clause do
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
