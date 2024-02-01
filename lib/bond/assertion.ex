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
  defstruct [:label, :expression, :code, :kind, :definition_env, :meta, :context]

  @type t :: %__MODULE__{
          label: Bond.assertion_label(),
          expression: Bond.assertion_expression(),
          code: String.t(),
          kind: Bond.assertion_kind(),
          definition_env: Bond.env(),
          meta: list(),
          context: map()
        }

  @assertion_errors %{
    precondition: Bond.PreconditionError,
    postcondition: Bond.PostconditionError,
    check: Bond.CheckError
  }

  defguard is_assertion_expression(expression)
           when is_tuple(expression) and
                  tuple_size(expression) == 3 and
                  is_atom(elem(expression, 0)) and is_list(elem(expression, 1)) and
                  is_list(elem(expression, 2))

  def new(kind, label, expression, %Macro.Env{} = env \\ __ENV__, meta \\ [])
      when is_assertion_expression(expression) do
    %__MODULE__{
      kind: kind,
      label: label,
      expression: expression,
      code: Macro.to_string(expression),
      definition_env: Bond.Env.new(env),
      meta: meta
    }
  end

  @doc """
  Returns a quoted expression that, when unquoted, evaluates the given `assertion`.
  """
  def quoted_eval(%__MODULE__{kind: kind, expression: expression} = assertion) do
    imports = imports(kind)
    exception = Map.fetch!(@assertion_errors, kind)

    quote do
      unquote(imports)

      if value = unquote(expression) do
        value
      else
        raise unquote(exception),
          assertion: unquote(Macro.escape(assertion)),
          env: __ENV__,
          binding: binding()
      end
    end
  end

  defp imports(:postcondition) do
    quote do
      import Bond.Predicates
      # import Bond.OldExpression
    end
  end

  defp imports(kind) when kind in [:precondition, :check] do
    quote do
      import Bond.Predicates
    end
  end

  defimpl String.Chars do
    def to_string(%Bond.Assertion{label: label, expression: expression, kind: kind}) do
      "#{kind}(#{inspect(label)}) => #{Macro.to_string(expression)}"
    end
  end
end
