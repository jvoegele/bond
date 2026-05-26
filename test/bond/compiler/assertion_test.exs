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

    test "accepts a local call as the outermost expression" do
      assertion = Assertion.new(:precondition, nil, quote(do: is_number(x)))
      assert assertion.code == "is_number(x)"
    end

    test "accepts an operator as the outermost expression" do
      assertion = Assertion.new(:postcondition, nil, quote(do: result >= 0))
      assert assertion.code == "result >= 0"
    end

    test "accepts a remote call as the outermost expression" do
      # AST head is `{:., _, [String, :starts_with?]}` — a 3-tuple, not an
      # atom. The relaxed guard accepts this shape.
      assertion = Assertion.new(:precondition, nil, quote(do: String.starts_with?(x, "foo")))
      assert assertion.code == ~s|String.starts_with?(x, "foo")|
    end

    test "accepts a remote call via Enum/Map/List" do
      a1 = Assertion.new(:precondition, nil, quote(do: Enum.all?(xs, &is_integer/1)))
      a2 = Assertion.new(:precondition, nil, quote(do: Map.has_key?(m, :k)))
      a3 = Assertion.new(:precondition, nil, quote(do: List.first(xs)))

      assert a1.code == "Enum.all?(xs, &is_integer/1)"
      assert a2.code == "Map.has_key?(m, :k)"
      assert a3.code == "List.first(xs)"
    end

    test "accepts an Erlang remote call" do
      assertion = Assertion.new(:precondition, nil, quote(do: :erlang.is_atom(x)))
      assert assertion.code == ":erlang.is_atom(x)"
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
