defmodule BondTest.MultiClauseInvariantTest do
  @moduledoc """
  Behavioural tests for the multi-clause pre-invariant fix (GitHub #22): a
  struct clause's `@invariant` must fire on entry even when the clause sits
  alongside a heterogeneous non-struct sibling clause.

  See `BondTest.MultiClauseInvariant` for the fixture and the root-cause notes.
  """

  use ExUnit.Case

  alias BondTest.MultiClauseInvariant, as: MCI

  describe "struct clause first" do
    test "pre-invariant fires on the struct clause for a violating struct" do
      assert_raise Bond.InvariantError, fn ->
        MCI.first_struct(struct(MCI, n: -1))
      end
    end

    test "pre-invariant passes for a valid struct" do
      assert MCI.first_struct(struct(MCI, n: 3)) == 3
    end

    test "the non-struct sibling clause still dispatches and is unaffected" do
      assert MCI.first_struct("hello") == {:binary, "hello"}
    end
  end

  describe "struct clause second (behind a guarded catch-all)" do
    test "pre-invariant fires on the struct clause for a violating struct" do
      assert_raise Bond.InvariantError, fn ->
        MCI.second_struct(struct(MCI, n: -1))
      end
    end

    test "pre-invariant passes for a valid struct" do
      assert MCI.second_struct(struct(MCI, n: 7)) == 7
    end

    test "the guarded sibling clause still dispatches (guard not dropped)" do
      assert MCI.second_struct("hi") == {:binary, "hi"}
    end
  end

  describe "guard referencing a destructured field name" do
    test "compiles and dispatches per the guard" do
      assert MCI.categorize(struct(MCI, n: 20)) == :big
      assert MCI.categorize(struct(MCI, n: 5)) == :small
    end

    test "pre-invariant fires on entry before the body, for a violating struct" do
      assert_raise Bond.InvariantError, fn ->
        MCI.categorize(struct(MCI, n: -1))
      end
    end
  end
end
