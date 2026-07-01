defmodule Bond.Runtime.QuantifierTest do
  @moduledoc """
  Unit tests for the `Bond.Runtime.Quantifier` helpers behind the `forall`/`exists` macros:
  boolean return values, short-circuit evaluation, vacuous/empty cases, the generator-pattern
  mismatch path (issue #55), and the per-process side channel (`pop/0`/`clear/0`) that carries
  element-level failure detail.

  The macros hand the runtime a function that returns `{:match, predicate_result}` for an
  element that matched the generator pattern, or `:no_match` for one that did not. These unit
  tests exercise the runtime directly, so `sat/1` wraps a boolean predicate into that
  convention and `nomatch_below/1` returns `:no_match` for elements a structural pattern would
  reject.

  Each ExUnit test runs in its own process, so the process-dictionary side channel is naturally
  isolated and these can stay `async: true`.
  """

  use ExUnit.Case, async: true

  alias Bond.Runtime.Quantifier

  setup do
    Quantifier.clear()
    :ok
  end

  # Wrap a boolean predicate into the `{:match, result}` convention the macros generate for an
  # element that matched the generator pattern.
  defp sat(fun), do: fn x -> {:match, fun.(x)} end

  # Mimic a structural generator pattern: elements `>= threshold` "match" (and satisfy the
  # trivially-true predicate); elements below it are `:no_match`.
  defp nomatch_below(threshold) do
    fn
      x when x >= threshold -> {:match, true}
      _ -> :no_match
    end
  end

  describe "forall/4" do
    test "returns true when the predicate holds for every element" do
      assert Quantifier.forall([1, 2, 3], sat(&(&1 > 0)), "x > 0", "x") == true
      assert Quantifier.pop() == nil
    end

    test "returns false and records the first violating element and index (predicate kind)" do
      assert Quantifier.forall([1, -2, 3, -4], sat(&(&1 > 0)), "x > 0", "x") == false

      assert Quantifier.pop() == %{
               quantifier: :forall,
               kind: :predicate,
               element: -2,
               index: 1,
               predicate: "x > 0"
             }
    end

    test "records a pattern-kind counterexample when an element does not match the generator" do
      assert Quantifier.forall([3, 4, -1, 5], nomatch_below(0), "true", "x when x >= 0") == false

      assert Quantifier.pop() == %{
               quantifier: :forall,
               kind: :pattern,
               element: -1,
               index: 2,
               pattern: "x when x >= 0"
             }
    end

    test "is vacuously true on an empty enumerable and records nothing" do
      assert Quantifier.forall([], sat(&(&1 > 0)), "x > 0", "x") == true
      assert Quantifier.pop() == nil
    end

    test "short-circuits at the first violating element" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn x ->
        Agent.update(counter, &(&1 + 1))
        {:match, x > 0}
      end

      Quantifier.forall([1, 2, -3, 4, 5], fun, "x > 0", "x")

      # Stops after the third element (the first that fails); the 4th and 5th are never seen.
      assert Agent.get(counter, & &1) == 3
    end

    test "clears stale detail on entry, so a passing call leaves the slot empty" do
      assert Quantifier.forall([-1], sat(&(&1 > 0)), "x > 0", "x") == false
      refute Quantifier.pop() == nil

      # A subsequent passing call must clear the slot it inherited.
      assert Quantifier.forall([1, 2], sat(&(&1 > 0)), "x > 0", "x") == true
      assert Quantifier.pop() == nil
    end
  end

  describe "exists/5" do
    test "returns true when the predicate holds for at least one element" do
      assert Quantifier.exists([1, 2, 3], sat(&(&1 > 2)), "x > 2", "list", "x") == true
      assert Quantifier.pop() == nil
    end

    test "returns false and records the element count when none satisfy (predicate kind)" do
      assert Quantifier.exists([1, 2, 3], sat(&(&1 > 5)), "x > 5", "list", "x") == false

      assert Quantifier.pop() == %{
               quantifier: :exists,
               kind: :predicate,
               predicate: "x > 5",
               count: 3,
               enum_code: "list"
             }
    end

    test "records a pattern-kind failure when no element matches the generator" do
      assert Quantifier.exists([-1, -2, -3], nomatch_below(0), "true", "list", "x when x >= 0") ==
               false

      assert Quantifier.pop() == %{
               quantifier: :exists,
               kind: :pattern,
               pattern: "x when x >= 0",
               count: 3,
               enum_code: "list"
             }
    end

    test "a mix of matching and non-matching elements reports the predicate, not the pattern" do
      # Two elements match the generator (0, 1) but none satisfy the predicate; one (-1) does
      # not match. Since some elements had the right shape, the predicate is the salient failure.
      fun = fn
        x when x >= 0 -> {:match, x > 100}
        _ -> :no_match
      end

      assert Quantifier.exists([0, 1, -1], fun, "x > 100", "list", "x when x >= 0") == false

      assert %{kind: :predicate, count: 3} = Quantifier.pop()
    end

    test "is false on an empty enumerable with a count of zero (predicate kind)" do
      assert Quantifier.exists([], sat(&(&1 > 0)), "x > 0", "[]", "x") == false

      assert Quantifier.pop() == %{
               quantifier: :exists,
               kind: :predicate,
               predicate: "x > 0",
               count: 0,
               enum_code: "[]"
             }
    end

    test "short-circuits at the first satisfying element" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn x ->
        Agent.update(counter, &(&1 + 1))
        {:match, x > 0}
      end

      Quantifier.exists([-1, -2, 3, 4], fun, "x > 0", "list", "x")

      # Stops at the third element (the first that satisfies); the 4th is never seen.
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "pop/0 and clear/0" do
    test "pop returns nil when the slot is empty" do
      assert Quantifier.pop() == nil
    end

    test "pop reads and clears, so a second pop returns nil" do
      Quantifier.forall([-1], sat(&(&1 > 0)), "x > 0", "x")
      assert is_map(Quantifier.pop())
      assert Quantifier.pop() == nil
    end

    test "clear empties a populated slot" do
      Quantifier.forall([-1], sat(&(&1 > 0)), "x > 0", "x")
      assert Quantifier.clear() == :ok
      assert Quantifier.pop() == nil
    end
  end
end
