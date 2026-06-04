defmodule Bond.InvariantTest do
  @moduledoc """
  End-to-end behavioural tests for `@invariant`. Drives the `BondTest.InvariantSmoke`
  fixture through the success and failure paths of every emission shape.
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.InvariantSmoke

  describe "pre-invariant check on entry" do
    test "passes when the input struct satisfies all invariants" do
      stack = InvariantSmoke.new(3)
      assert %InvariantSmoke{} = InvariantSmoke.push(stack, :a)
    end

    test "fails on entry when the input struct violates an invariant" do
      # Bypasses InvariantSmoke.new so we can hand-construct an invalid struct that
      # already violates `size_within_capacity`.
      invalid = %InvariantSmoke{items: [:a, :b, :c], capacity: 1}

      assert_raise Bond.InvariantError, fn ->
        InvariantSmoke.push(invalid, :d)
      end
    end

    test "the pre-invariant error identifies the offending label" do
      invalid = %InvariantSmoke{items: [:a, :b], capacity: 1}

      error =
        assert_invariant_violation(InvariantSmoke.push(invalid, :c),
          label: :size_within_capacity,
          module: BondTest.InvariantSmoke,
          function: {:push, 2}
        )

      assert error.label == :size_within_capacity
    end
  end

  describe "post-invariant check on exit" do
    test "passes when the returned struct satisfies all invariants" do
      stack = InvariantSmoke.new(3)
      assert %InvariantSmoke{items: [:a]} = InvariantSmoke.push(stack, :a)
    end

    test "fails when the returned struct violates an invariant" do
      stack = InvariantSmoke.new(2)

      assert_raise Bond.InvariantError, fn ->
        # broken_push pushes 4 items, exceeding capacity 2.
        InvariantSmoke.broken_push(stack, :a)
      end
    end
  end

  describe "exit order (ECMA-367 §8.23.26)" do
    test "post-invariant is evaluated before the postcondition" do
      # overflowing_post violates BOTH its `@post must_shrink` postcondition and
      # the `size_within_capacity` invariant on return. ECMA-367 evaluates the
      # invariant (step 12) before the postcondition (step 13), so the invariant
      # error must be the one raised. If the order regressed, a
      # Bond.PostconditionError would surface instead.
      stack = InvariantSmoke.new(2)

      assert_raise Bond.InvariantError, fn ->
        InvariantSmoke.overflowing_post(stack, :a)
      end
    end
  end

  describe "{:ok, struct} return extraction" do
    test "passes when the wrapped struct satisfies all invariants" do
      assert {:ok, %InvariantSmoke{capacity: 3}} = InvariantSmoke.try_new(3)
    end

    test "skips invariant check when the return is {:error, _}" do
      # try_new/1 with a non-integer returns {:error, _}; the case-extraction skips
      # the invariant check, so this should not raise even though no struct was
      # produced.
      assert {:error, :invalid_capacity} = InvariantSmoke.try_new(:not_an_integer)
    end
  end

  describe "non-struct returns" do
    test "skips post-invariant check when result isn't the struct" do
      stack = InvariantSmoke.new(5)
      # capacity/1 returns an integer; the case-extraction's fall-through branch
      # runs (no invariant check), so this completes normally.
      assert 5 = InvariantSmoke.capacity(stack)
    end
  end

  describe "defp exemption (Eiffel convention)" do
    test "private functions can transiently break the invariant without firing the check" do
      stack = InvariantSmoke.new(2)

      # `bypass_invariants_via_defp` calls a `defp` that produces a struct exceeding
      # capacity, then returns it from a `def` that has the pattern-bound arg. The
      # pre-invariant on the `def` passes (input is valid). The post-invariant fails
      # (the returned struct from the defp is invalid). This demonstrates that defp
      # bypasses the invariant — but the surrounding def still enforces on its own
      # entry/exit.
      assert_raise Bond.InvariantError, fn ->
        InvariantSmoke.bypass_invariants_via_defp(stack, :a)
      end
    end
  end
end
