defmodule Bond.OldExpression do
  @moduledoc internal: true
  @moduledoc """
  Support for the `old` construct that can be used in postconditions for capturing values prior
  to execution of a function.
  """

  alias Bond.Assertion

  @opaque old_context :: %{String.t() => Bond.assertion_expression()} | %{}

  @doc """
  Transforms `postconditions` such that any `old` expressions are in resolvable form.

  The `postconditions` argument must be a list of `%Bond.Assertion{kind: :postcondition}`
  structs, since old expressions are valid only in postconditions.

  Returns a tuple containing the transformed postconditions and an opaque value that can be
  provided to `resolve/1` for resolving old expressions to their runtime value prior to function
  execution.
  """
  @spec precompile([%Bond.Assertion{kind: :postcondition}]) :: {Macro.t(), old_context()}
  def precompile(postconditions) when is_list(postconditions) do
    {precompiled_postconditions, old_table} =
      for postcondition <- postconditions, reduce: {[], %{}} do
        acc ->
          accumulate_old_expressions(postcondition, acc)
      end

    {Enum.reverse(precompiled_postconditions), old_table}
  end

  @doc """
  Resolves old expressions in the given `old_context` to their runtime values.

  The runtime value of each old expression is a snapshot obtained by unquoting the expression
  within the body of the associated function, just prior to executing the function body. These
  snapshot values are saved in local variables, which are then accessed when evaluating the
  postconditions after the function has finished its normal execution. Note that these local
  variables are not hygienized and therefore are accessible within the body of the function
  associated with the postconditions, and will also appear in the `binding/0` of the function.

  Returns a list of quoted expressions that, when evaluated with `unquote_splicing/1`, inject
  local variables (containing snapshot values for the old expressions) into the calling context.
  """
  @spec resolve(old_context()) :: term()
  def resolve(empty_map) when empty_map == %{}, do: []

  def resolve(old_context) do
    for {key, expression} <- old_context do
      var = make_var(key)

      quote generated: true do
        var!(unquote(var)) = unquote(expression)
      end
    end
  end

  defp make_key(old_expression), do: Macro.to_string(old_expression)

  defp make_var(key), do: Macro.var(String.to_atom("old(#{key})"), nil)

  defp accumulate_old_expressions(
         %Assertion{kind: :postcondition, expression: expression} = assertion,
         {postconditions_acc, old_table}
       ) do
    {updated_expression, updated_old_table} =
      Macro.prewalk(expression, old_table, fn
        {:old, _meta, [old_expression]}, old_table ->
          key = make_key(old_expression)
          var = make_var(key)
          {var, Map.put(old_table, key, old_expression)}

        {:old, _, _}, _old_table_acc ->
          raise CompileError, description: "invalid old expression"

        other, old_table ->
          {other, old_table}
      end)

    updated_assertion = %{assertion | expression: updated_expression}
    {[updated_assertion | postconditions_acc], updated_old_table}
  end
end
