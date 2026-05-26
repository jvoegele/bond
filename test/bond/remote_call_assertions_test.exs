defmodule Bond.RemoteCallAssertionsTest do
  @moduledoc """
  Behavioural tests for remote-function-call expressions as bare assertions.
  Pre-0.16.2 these required a `== true` suffix to compile; this verifies
  the relaxed `Assertion.is_assertion_expression/1` guard accepts them
  end-to-end (compile, run, raise on violation).
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.RemoteCallAssertions, as: Fix

  describe "remote call in @pre" do
    test "passes when the precondition holds" do
      assert Fix.greet("user-jane") == "hello, user-jane"
    end

    test "raises when the precondition fails" do
      assert_precondition_violation(Fix.greet("admin-jane"),
        expression: ~r/String\.starts_with\?/
      )
    end
  end

  describe "remote call in @post" do
    test "passes when the postcondition holds" do
      assert Fix.squares(3) == [0, 1, 4, 9]
    end
  end

  describe "remote call against a Map predicate in @pre" do
    test "passes with a map containing the required key" do
      assert Fix.fetch_id(%{id: 42}) == 42
    end

    test "raises when the required key is missing" do
      assert_precondition_violation(Fix.fetch_id(%{name: "x"}),
        expression: ~r/Map\.has_key\?/
      )
    end
  end

  describe "remote call in @invariant" do
    test "passes when the result struct satisfies the invariant" do
      empty = %Fix{items: []}
      assert %Fix{items: [:a]} = Fix.push_atom(empty, :a)
    end

    test "raises when input violates the invariant" do
      invalid = %Fix{items: ["string-not-atom"]}

      assert_raise Bond.InvariantError, fn ->
        Fix.push_atom(invalid, :a)
      end
    end
  end

  describe "remote call in check/1" do
    test "passes when the check holds" do
      assert Fix.inline_check_example([1, 2, 3]) == [1, 2, 3]
    end

    test "raises when the check fails" do
      assert_raise Bond.CheckError, fn -> Fix.inline_check_example([nil, 2]) end
    end
  end
end
