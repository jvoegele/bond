defmodule Bond.OldRuntimeTest do
  @moduledoc """
  Behavioural tests for `old(...)` expressions in postconditions. Verifies that
  values snapshotted at function entry are correctly bound at postcondition
  evaluation time, both on the success path (the postcondition holds) and the
  failure path (a `PostconditionError` surfaces with the captured-old context).

  The compiler-level transformation of `old(...)` is covered separately in
  `Bond.Compiler.OldExpressionTest`; this file complements it by driving the
  end-to-end runtime path.
  """

  use ExUnit.Case, async: false

  defmodule Fixture do
    @moduledoc false
    use Bond

    @post incremented: result == old(x) + 1
    def increment(x), do: x + 1

    # Returns x unchanged so the postcondition `result == old(x) + 1` is
    # guaranteed to fail.
    @post incremented: result == old(x) + 1
    def broken_increment(x), do: x

    # Stateful read inside `old(...)` — exercises the snapshot at entry rather
    # than re-evaluating at exit.
    def get_count(agent), do: Agent.get(agent, & &1)

    @post grew: result == old(get_count(agent)) + 1
    def increment_in_agent(agent) do
      Agent.update(agent, &(&1 + 1))
      Agent.get(agent, & &1)
    end
  end

  describe "old() success path" do
    test "snapshotted value at entry matches postcondition arithmetic" do
      assert Fixture.increment(5) == 6
    end

    test "old() captures the value of a stateful read at function entry" do
      {:ok, agent} = Agent.start_link(fn -> 10 end)
      assert Fixture.increment_in_agent(agent) == 11
    end
  end

  describe "old() failure path" do
    test "PostconditionError carries the failing assertion's label and expression" do
      error =
        assert_raise Bond.PostconditionError, fn ->
          Fixture.broken_increment(5)
        end

      assert error.label == :incremented
      assert error.expression =~ "old(x)"
      assert error.function == {:broken_increment, 1}
    end

    test "binding at failure includes x; result is the actual (broken) return" do
      error =
        assert_raise Bond.PostconditionError, fn ->
          Fixture.broken_increment(42)
        end

      # `x` came in as 42; `result` is the (incorrect) returned value, also 42.
      # The postcondition expected `result == old(x) + 1` (= 43) but got 42.
      assert error.binding[:x] == 42
      assert error.binding[:result] == 42
    end
  end
end
