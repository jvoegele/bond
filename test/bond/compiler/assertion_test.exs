defmodule Bond.Compiler.AssertionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Assertion

  describe "new/5" do
    test "generates unique id" do
      %Assertion{id: id} = Assertion.new(:precondition, nil, quote(do: x > 0))
      assert is_binary(id)
      assert id =~ ~r/^[[:alnum:]]+$/
    end
  end

  describe "create_assertions_function/2" do
    test "creates anonymous function that evaluates assertions when invoked" do
    end
  end
end
