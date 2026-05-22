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

  describe "assertions_body/2" do
    test "produces a block whose code throws {:assertion_failure, info} on a false assertion" do
      assertion = Assertion.new(:precondition, :positive, quote(do: x > 0), __ENV__)
      body = Assertion.assertions_body([assertion], {:f, 1})
      code = Macro.to_string(body)

      assert code =~ ~r"import Bond\.Predicates"
      assert code =~ ~r"if x > 0"
      assert code =~ ~r"throw"
      assert code =~ ~r":assertion_failure"
    end
  end

  describe "check_body/1" do
    test "produces a block that returns the check expression's value on success" do
      assertion = Assertion.new(:check, nil, quote(do: 1 + 1), __ENV__)
      body = Assertion.check_body(assertion)
      code = Macro.to_string(body)

      assert code =~ ~r"import Bond\.Predicates"
      assert code =~ ~r"value = 1 \+ 1"
      assert code =~ ~r"throw"
    end
  end
end
