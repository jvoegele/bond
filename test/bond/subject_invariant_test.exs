defmodule Bond.SubjectInvariantTest do
  @moduledoc """
  Behavioural tests for the 0.16.0 `@invariant <expr_or_kw>` syntax. Drives the
  `BondTest.SubjectInvariantSmoke` fixture through every detection shape:
  `%__MODULE__{} = name`, `is_struct(_, __MODULE__)` guard, and multi-struct heads
  with `subject` rebinding between checks.
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.SubjectInvariantSmoke, as: Smoke

  describe "pre-invariant (subject auto-binding)" do
    test "passes when the input struct satisfies all invariants" do
      assert %Smoke{} = Smoke.push(Smoke.new(3), :a)
    end

    test "fails when input violates an invariant" do
      invalid = %Smoke{items: [:a, :b, :c], capacity: 1}
      assert_raise Bond.InvariantError, fn -> Smoke.push(invalid, :d) end
    end

    test "labels the failure with the invariant's label" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}

      error =
        assert_invariant_violation(Smoke.push(invalid, :c),
          label: :size_within_capacity,
          module: BondTest.SubjectInvariantSmoke,
          function: {:push, 2}
        )

      assert error.label == :size_within_capacity
    end
  end

  describe "post-invariant (subject auto-binding)" do
    test "fails when result violates an invariant" do
      stack = Smoke.new(2)

      assert_raise Bond.InvariantError, fn ->
        Smoke.broken_push(stack, :a)
      end
    end
  end

  describe "is_struct/2 guard form" do
    test "pre-invariant fires for guard-detected struct param" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}
      assert_raise Bond.InvariantError, fn -> Smoke.reverse(invalid) end
    end

    test "passes when guard-detected struct is valid" do
      stack = Smoke.push(Smoke.new(3), :a)
      assert %Smoke{items: [:a]} = Smoke.reverse(stack)
    end
  end

  describe "multi-struct heads" do
    test "both struct params trigger pre-invariant checks" do
      assert %Smoke{} = Smoke.concat(Smoke.new(2), Smoke.new(2))
    end

    test "invalid first arg raises (subject rebinds to first)" do
      invalid_a = %Smoke{items: [:x, :y], capacity: 1}
      b = Smoke.new(2)
      assert_raise Bond.InvariantError, fn -> Smoke.concat(invalid_a, b) end
    end

    test "invalid second arg raises (subject rebinds to second)" do
      a = Smoke.new(2)
      invalid_b = %Smoke{items: [:x, :y, :z], capacity: 1}
      assert_raise Bond.InvariantError, fn -> Smoke.concat(a, invalid_b) end
    end
  end

  describe "non-zero-position struct param" do
    test "detects struct at parameter index 1" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}

      assert_raise Bond.InvariantError, fn ->
        Smoke.mismatched_pair(:tag, invalid)
      end
    end

    test "passes a valid struct through" do
      stack = Smoke.new(3)
      assert {:tag, %Smoke{}} = Smoke.mismatched_pair(:tag, stack)
    end
  end
end
