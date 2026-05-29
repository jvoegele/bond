defmodule Bond.QualifiedSyntaxTest do
  @moduledoc """
  Verifies the `use Bond, at_syntax: false` escape hatch: contracts written as
  fully-qualified `Bond.pre` / `Bond.post` / `Bond.invariant` calls enforce identically to
  the `@`-prefixed forms, without Bond overriding `Kernel.@/1` in the using module.

  Fixture source: `test/support/bond_test/qualified_syntax.ex`.
  """

  use ExUnit.Case

  alias BondTest.QualifiedSyntax, as: Q

  describe "Bond.pre/1 and Bond.post/1 (bare)" do
    test "happy path passes pre and post" do
      assert Q.double(3) == 6
    end

    test "precondition violation raises Bond.PreconditionError" do
      assert_raise Bond.PreconditionError, fn -> Q.double(-1) end
    end

    test "postcondition violation raises Bond.PostconditionError" do
      assert Q.passthrough(5) == 5
      assert_raise Bond.PostconditionError, fn -> Q.passthrough(-5) end
    end
  end

  describe "Bond.pre/1 keyword list (labelled)" do
    test "passes when every labelled precondition holds" do
      assert Q.bounded(50) == 50
    end

    test "raises when any labelled precondition fails" do
      assert_raise Bond.PreconditionError, fn -> Q.bounded(0) end
      assert_raise Bond.PreconditionError, fn -> Q.bounded(150) end
    end
  end

  describe "Bond.pre/2 (label-first and label-last)" do
    test "label-first form enforces" do
      assert Q.label_first(5) == 5
      assert_raise Bond.PreconditionError, fn -> Q.label_first(0) end
    end

    test "label-last form enforces" do
      assert Q.label_last(5) == 5
      assert_raise Bond.PreconditionError, fn -> Q.label_last(0) end
    end
  end

  describe "Bond.invariant/1" do
    test "a function that preserves the invariant succeeds" do
      stack = Q.new(3)
      assert Q.push(stack, :a).items == [:a]
    end

    test "violating an invariant raises Bond.InvariantError" do
      stack = Q.new(0)
      assert_raise Bond.InvariantError, fn -> Q.overfill(stack, :x) end
    end
  end
end
