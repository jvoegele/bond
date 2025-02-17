defmodule Bond.Compiler.AnnotatedFunctionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.FunctionDefinition

  setup [:setup_function_definitions]

  describe "new/1" do
    test "creates a new struct from the given FunctionDefinition", %{
      function_definitions: [function_def | _]
    } do
      assert %AnnotatedFunction{} = annotated_function = AnnotatedFunction.new(function_def)

      assert annotated_function.kind == function_def.kind
    end
  end

  describe "Clause.new/1" do
    test "creates a new instance of the Clause struct from the given FunctionDefinition", %{
      function_definitions: [function_def | _]
    } do
      assert %AnnotatedFunction.Clause{} = clause = AnnotatedFunction.Clause.new(function_def)

      assert clause.env == function_def.env
      assert clause.params == function_def.params
      assert clause.guards == function_def.guards
      assert clause.body == function_def.body
    end
  end

  defp setup_function_definitions(_context) do
    env = __ENV__
    kind = :def
    fun = :testing
    params = [:x, :y]
    guards = []
    body = quote(do: :ok)
    function_def = FunctionDefinition.new(env, kind, fun, params, guards, body)

    {:ok, function_definitions: [function_def]}
  end
end
