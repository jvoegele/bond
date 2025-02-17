defmodule Bond.Compiler.AnnotatedFunctionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.FunctionDefinition

  describe "Clause.new/1" do
    test "creates a new instance of the Clause struct from the given FunctionDefinition" do
      env = __ENV__
      kind = :def
      fun = :testing
      params = [:x, :y]
      guards = []
      body = quote(do: :ok)
      function_def = FunctionDefinition.new(env, kind, fun, params, guards, body)

      assert %AnnotatedFunction.Clause{} = clause = AnnotatedFunction.Clause.new(function_def)

      assert clause.env == env
      assert clause.params == params
      assert clause.guards == guards
      assert clause.body == body
    end
  end
end
