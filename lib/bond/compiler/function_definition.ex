defmodule Bond.Compiler.FunctionDefinition do
  @moduledoc internal: true
  @moduledoc """
  Struct containing information about a function definition at compile time.

  This struct represents a single `def` or `defp` at compile time, so there will be separate
  instances of the struct for each clause of a multi-clause function.
  """

  defstruct env: nil,
            kind: nil,
            module: nil,
            fun: nil,
            arity: nil,
            params: nil,
            guards: nil,
            body: nil

  @type doc_attribute_value :: String.t() | Keyword.t()
  @type doc_attribute :: {meta :: Keyword.t(), value :: doc_attribute_value()}

  @type kind :: :def | :defp

  @type function_parameters :: list()
  @type function_guards :: list()
  @type function_body :: list() | nil

  @type clause :: {Macro.Env.t(), function_parameters(), function_guards(), function_body()}

  @type t :: %__MODULE__{
          env: Macro.Env.t(),
          kind: kind(),
          module: module(),
          fun: atom(),
          params: list(),
          guards: list(),
          body: list() | nil
        }

  @spec new(
          env :: Macro.Env.t(),
          kind :: kind(),
          fun :: atom(),
          params :: list(),
          guards :: list(),
          body :: list() | nil
        ) :: t()
  def new(%Macro.Env{} = env, kind, fun, params, guards, body) when kind in [:def, :defp] do
    %__MODULE__{
      env: env,
      kind: kind,
      module: env.module,
      fun: fun,
      arity: length(params),
      params: params,
      guards: guards,
      body: body
    }
  end

  def mfa(%__MODULE__{module: module, fun: function, params: params}) do
    {module, function, length(params)}
  end

  def mfa(_), do: nil
end
