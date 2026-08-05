defmodule Bond.NestedStructHeadTest do
  @moduledoc """
  #84: invariant entry checks for a struct carried inside a tuple, map, or list pattern.

  Before this, detection only classified *top-level* head parameters, so a function
  taking `{:wrapped, %__MODULE__{} = s}` got an entry check only by accident — if it
  happened to return the struct, the exit check covered it. A function that took one and
  returned something else was unchecked, silently: the struct is "mentioned", so
  `:warn_skipped_invariants` stayed quiet too.

  Every fixture function discards the struct, so a raise here is the entry check.
  """

  use ExUnit.Case, async: true

  alias BondTest.NestedStructHeads, as: N

  defp bad, do: %N{v: -5}
  defp good, do: %N{v: 5}

  describe "entry check fires for a struct nested in the head" do
    test "inside a tuple" do
      assert_raise Bond.InvariantError, fn -> N.from_tuple({:wrapped, bad()}) end
      assert N.from_tuple({:wrapped, good()}) == {:ok, 5}
    end

    test "inside a map" do
      assert_raise Bond.InvariantError, fn -> N.from_map(%{payload: bad()}) end
      assert N.from_map(%{payload: good()}) == {:ok, 5}
    end

    test "inside a list" do
      assert_raise Bond.InvariantError, fn -> N.from_list([bad()]) end
      assert N.from_list([good(), good()]) == {:ok, 5}
    end

    test "nested two levels deep" do
      assert_raise Bond.InvariantError, fn -> N.from_nested({:outer, {:inner, bad()}}) end
      assert N.from_nested({:outer, {:inner, good()}}) == {:ok, 5}
    end

    test "with the match written in reverse" do
      assert_raise Bond.InvariantError, fn -> N.reversed({:wrapped, bad()}) end
      assert N.reversed({:wrapped, good()}) == {:ok, 5}
    end
  end

  describe "multiple structs nested in one head" do
    test "either one violating is caught" do
      assert_raise Bond.InvariantError, fn -> N.pair({bad(), good()}) end
      assert_raise Bond.InvariantError, fn -> N.pair({good(), bad()}) end
      assert N.pair({good(), good()}) == {:ok, 5, 5}
    end
  end

  describe "documented limit" do
    test "a destructure-only nested pattern binds nothing, so nothing is checked" do
      # `{:wrapped, %__MODULE__{v: v}}` — the guide's head-shape table says to add
      # `= name` if you want the entry check here.
      assert N.destructure_only({:wrapped, bad()}) == {:ok, -5}
    end
  end
end
