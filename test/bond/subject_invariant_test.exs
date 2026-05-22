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

  describe "destructure-only struct param" do
    test "pre-invariant fires on a destructure-only head when input violates" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}
      assert_raise Bond.InvariantError, fn -> Smoke.head(invalid) end
    end

    test "destructure-only head passes through and returns the destructured value" do
      stack = Smoke.push(Smoke.new(3), :a)
      assert :a == Smoke.head(stack)
    end

    test "destructure-only head with post-invariant: invalid input raises pre-check" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}
      assert_raise Bond.InvariantError, fn -> Smoke.rotate(invalid) end
    end

    test "destructure-only head with post-invariant: result struct passes both checks" do
      stack = Smoke.push(Smoke.push(Smoke.new(3), :a), :b)
      assert %Smoke{items: [:a, :b]} = Smoke.rotate(stack)
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

  describe "compound `and` guard containing is_struct" do
    test "pre-invariant fires for is_struct nested inside `and`" do
      invalid = %Smoke{items: [:a, :b], capacity: 1}

      assert_raise Bond.InvariantError, fn ->
        Smoke.guarded_and(invalid, 0)
      end
    end

    test "passes through when input satisfies the invariant" do
      stack = Smoke.new(3)
      assert %Smoke{capacity: 5} = Smoke.guarded_and(stack, 2)
    end
  end

  describe "function head with no struct parameter" do
    test "function with no struct in head doesn't fire pre-invariant" do
      # The module has `@invariant subject.capacity >= 0` etc., but const_zero/1
      # has no struct param. If a pre-invariant fired on the non-struct input,
      # evaluating `subject.capacity` on `:any_atom` would crash. A clean return
      # value proves no pre-invariant ran.
      assert Smoke.const_zero(:any_atom) == 0
      assert Smoke.const_zero(42) == 0
    end
  end
end
