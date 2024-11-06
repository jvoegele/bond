defmodule Bond.FunctionWithContract do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for attaching contracts (i.e. preconditions and/or postconditions) to a
  function.
  """

  alias Bond.Assertion
  alias Bond.OldExpression

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
      env: Bond.Env.new(env),
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
          unquote(old_resolved_ast)
          unquote(preconditions_fun).()

          var!(result) = unquote(do_block)

          unquote(postconditions_fun).()

          var!(result)
        end
      end)

    %{function | body_ast: wrapped_body}
  end

  def _set_evaluating_assertions(bool) when is_boolean(bool) do
    Process.put(:__bond_evaluating_assertions__, bool)
  end

  def _evaluating_assertions? do
    Process.get(:__bond_evaluating_assertions__, false)
  end

  defp create_assertions_function(assertions) do
    assertions_ast = Enum.map(assertions, &Assertion.quoted_eval/1)

    quote do
      fn ->
        # Mutually recursive contracts lead to infinite recursion, so don't evaluate assertions for a
        # function if they are already being evaluated for the original function call.
        #
        # Assertion Evaluation rule (from Object-Oriented Software Construction):
        # During the process of evaluating an assertion at run-time, routine calls shall
        # be executed without any evaluation of the associated assertions.
        if not Bond.FunctionWithContract._evaluating_assertions?() do
          Bond.FunctionWithContract._set_evaluating_assertions(true)

          try do
            (unquote_splicing(assertions_ast))
          after
            Bond.FunctionWithContract._set_evaluating_assertions(false)
          end
        end
      end
    end
  end

  defp function_id({:when, _, [{name, _, params} | _]}) when is_list(params),
    do: {name, length(params)}

  defp function_id({name, _, nil}), do: {name, 0}
  defp function_id({name, _, params}) when is_list(params), do: {name, length(params)}
end
