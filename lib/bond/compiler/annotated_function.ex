defmodule Bond.Compiler.AnnotatedFunction do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for attaching contracts (i.e. preconditions and/or postconditions) to a
  function.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.OldExpression

  defstruct [
    :env,
    :module,
    :function,
    :arity,
    :body_ast
  ]

  def new(%Macro.Env{} = env, definition, body) do
    {function, arity} = function_id(definition)

    %__MODULE__{
      env: env,
      module: env.module,
      function: function,
      arity: arity,
      body_ast: body
    }
  end

  def mfa(%__MODULE__{} = function) do
    {function.module, function.function, function.arity}
  end

  def apply_contract(%__MODULE__{} = function, [] = _preconditions, [] = _postconditions) do
    function
  end

  def apply_contract(%__MODULE__{body_ast: body} = function, preconditions, postconditions) do
    {postconditions, old_context} = OldExpression.precompile(postconditions)
    old_resolved_ast = old_context |> OldExpression.resolve()

    preconditions_fun = create_assertions_function(preconditions)
    postconditions_fun = create_assertions_function(postconditions)

    wrapped_body =
      Keyword.update!(body, :do, fn do_block ->
        quote do
          preconditions_fun = unquote(preconditions_fun)
          Bond.Runtime.Eval.evaluate_preconditions(preconditions_fun)

          unquote(old_resolved_ast)

          var!(result) = unquote(do_block)

          postconditions_fun = unquote(postconditions_fun)
          Bond.Runtime.Eval.evaluate_postconditions(postconditions_fun)

          var!(result)
        end
      end)

    %{function | body_ast: wrapped_body}
  end

  defp create_assertions_function(assertions) do
    assertions_ast = Enum.map(assertions, &Assertion.quoted_eval/1)

    quote do
      fn ->
        (unquote_splicing(assertions_ast))
      end
    end
  end

  defp function_id({:when, _, [{name, _, params} | _]}) when is_list(params),
    do: {name, length(params)}

  defp function_id({name, _, nil}), do: {name, 0}
  defp function_id({name, _, params}) when is_list(params), do: {name, length(params)}
end
