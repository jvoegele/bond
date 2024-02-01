defmodule Bond.OldExpressionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Assertion
  alias Bond.OldExpression

  setup [:setup_postconditions]

  describe "precompile/1" do
    test "translates postconditions with old expressions into resolvable form", %{
      postconditions: postconditions
    } do
      assert {[_ | _] = precompiled_postconditions, _} = OldExpression.precompile(postconditions)
      assert length(precompiled_postconditions) == length(postconditions)

      [post1, post2, post3, post4] = precompiled_postconditions

      assert post1.code == "old(x)"
      assert post1.expression == {:"old(x)", [], nil}

      assert post2.code == "x > old(x)"
      assert {:>, _, [{:x, _, _}, {:"old(x)", [], nil}]} = post2.expression

      assert post3.code == "old(length(enum))"
      assert {:"old(length(enum))", [], nil} = post3.expression

      assert post4.code == "length(list) = old(length(list)) + 1"

      assert {:=, _,
              [
                {:length, _, [{:list, _, _}]},
                {:+, _, [{:"old(length(list))", [], nil}, 1]}
              ]} = post4.expression
    end

    test "builds a table of old expressions contained in postconditions", %{
      postconditions: postconditions
    } do
      assert {_, %{} = old_table} = OldExpression.precompile(postconditions)

      expected_keys = Enum.sort(["x", "length(enum)", "length(list)"])

      assert Enum.sort(Map.keys(old_table)) == expected_keys

      assert {:x, _, _} = old_table["x"]
      assert {:length, _, [{:enum, [], _}]} = old_table["length(enum)"]
      assert {:length, _, [{:list, [], _}]} = old_table["length(list)"]
    end
  end

  describe "resolve/1" do
  end

  defp setup_postconditions(_context) do
    postconditions = [
      build_postcondition(quote(do: old(x))),
      build_postcondition(quote(do: x > old(x))),
      build_postcondition(quote(do: old(length(enum)))),
      build_postcondition(quote(do: length(list) = old(length(list)) + 1))
    ]

    {:ok, postconditions: postconditions}
  end

  defp build_postcondition(expression) do
    Assertion.new(:postcondition, nil, expression)
  end
end
