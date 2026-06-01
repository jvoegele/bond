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
end
