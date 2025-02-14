defmodule Bond.Compiler.FunctionDefinitionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.FunctionDefinition

  @params [{:stack, [line: 80], nil}, {:elem, [line: 80], nil}]
  @guards [{:is_integer, [line: 32], [{:capacity, [line: 32], nil}]}]
  @body [do: {:new, [line: 46], [{:round, [line: 46], [{:capacity, [line: 46], nil}]}]}]

  describe "new/6" do
    test "creates a new struct in initial state" do
      env = __ENV__

      assert %FunctionDefinition{} =
               function_def = FunctionDefinition.new(env, :def, :foo, @params, @guards, @body)

      assert function_def.kind == :def
      assert function_def.module == __MODULE__
      assert function_def.fun == :foo
      assert function_def.arity == length(@params)
    end
  end
end
