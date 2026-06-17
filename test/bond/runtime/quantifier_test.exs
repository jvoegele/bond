defmodule Bond.Runtime.QuantifierTest do
  @moduledoc """
  Unit tests for the `Bond.Runtime.Quantifier` helpers behind the `forall`/`exists` macros:
  boolean return values, short-circuit evaluation, vacuous/empty cases, and the per-process
  side channel (`pop/0`/`clear/0`) that carries element-level failure detail.

  Each ExUnit test runs in its own process, so the process-dictionary side channel is naturally
  isolated and these can stay `async: true`.
  """

  use ExUnit.Case, async: true

  alias Bond.Runtime.Quantifier

  setup do
    Quantifier.clear()
    :ok
  end

  describe "forall/3" do
    test "returns true when the predicate holds for every element" do
      assert Quantifier.forall([1, 2, 3], &(&1 > 0), "x > 0") == true
      assert Quantifier.pop() == nil
    end

    test "returns false and records the first violating element and index" do
      assert Quantifier.forall([1, -2, 3, -4], &(&1 > 0), "x > 0") == false

      assert Quantifier.pop() == %{
               quantifier: :forall,
               element: -2,
               index: 1,
               predicate: "x > 0"
             }
    end

    test "is vacuously true on an empty enumerable and records nothing" do
      assert Quantifier.forall([], &(&1 > 0), "x > 0") == true
      assert Quantifier.pop() == nil
    end

    test "short-circuits at the first violating element" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn x ->
        Agent.update(counter, &(&1 + 1))
        x > 0
      end

      Quantifier.forall([1, 2, -3, 4, 5], fun, "x > 0")

      # Stops after the third element (the first that fails); the 4th and 5th are never seen.
      assert Agent.get(counter, & &1) == 3
    end

    test "clears stale detail on entry, so a passing call leaves the slot empty" do
      assert Quantifier.forall([-1], &(&1 > 0), "x > 0") == false
      refute Quantifier.pop() == nil

      # A subsequent passing call must clear the slot it inherited.
      assert Quantifier.forall([1, 2], &(&1 > 0), "x > 0") == true
      assert Quantifier.pop() == nil
    end
  end

  describe "exists/4" do
    test "returns true when the predicate holds for at least one element" do
      assert Quantifier.exists([1, 2, 3], &(&1 > 2), "x > 2", "list") == true
      assert Quantifier.pop() == nil
    end

    test "returns false and records the element count when none satisfy" do
      assert Quantifier.exists([1, 2, 3], &(&1 > 5), "x > 5", "list") == false

      assert Quantifier.pop() == %{
               quantifier: :exists,
               predicate: "x > 5",
               count: 3,
               enum_code: "list"
             }
    end

    test "is false on an empty enumerable with a count of zero" do
      assert Quantifier.exists([], &(&1 > 0), "x > 0", "[]") == false

      assert Quantifier.pop() == %{
               quantifier: :exists,
               predicate: "x > 0",
               count: 0,
               enum_code: "[]"
             }
    end

    test "short-circuits at the first satisfying element" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      fun = fn x ->
        Agent.update(counter, &(&1 + 1))
        x > 0
      end

      Quantifier.exists([-1, -2, 3, 4], fun, "x > 0", "list")

      # Stops at the third element (the first that satisfies); the 4th is never seen.
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "pop/0 and clear/0" do
    test "pop returns nil when the slot is empty" do
      assert Quantifier.pop() == nil
    end

    test "pop reads and clears, so a second pop returns nil" do
      Quantifier.forall([-1], &(&1 > 0), "x > 0")
      assert is_map(Quantifier.pop())
      assert Quantifier.pop() == nil
    end

    test "clear empties a populated slot" do
      Quantifier.forall([-1], &(&1 > 0), "x > 0")
      assert Quantifier.clear() == :ok
      assert Quantifier.pop() == nil
    end
  end
end
