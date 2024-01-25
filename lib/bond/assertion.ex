defmodule Bond.Assertion do
  @moduledoc internal: true
  @moduledoc """
  Struct representing assertions that appear as part of contract specifications, such as in
  preconditions or postconditions attached to functions.

  Assertions are constructed at compile-time and as such the fields in this struct are quoted
  expressions or compile-time environment data. At run-time, the assertion `:expression` is
  evaluated by unquoting it in the context of the function to which the assertion is attached.
  """

  @enforce_keys [:expression, :kind, :definition_env, :meta]
  defstruct [:label, :expression, :kind, :definition_env, :meta]

  @type t :: %__MODULE__{
          label: Bond.assertion_label(),
          expression: Bond.assertion_expression(),
          kind: Bond.assertion_kind(),
          definition_env: Bond.env(),
          meta: list()
        }

  defimpl String.Chars do
    def to_string(%Bond.Assertion{label: label, expression: expression, kind: kind}) do
      "#{kind}(#{inspect(label)}) => #{Macro.to_string(expression)}"
    end
  end
end
