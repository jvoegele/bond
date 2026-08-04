defmodule Bond.CanonicalNameCollisionTest do
  @moduledoc """
  Regression tests for the canonical-name collision found while working on #75.

  The canonical name for a position is agreed across all clauses, so one clause
  can end up with a canonical name that its own pattern already binds further
  down — a sibling clause names the whole argument `key`, while this clause
  destructures `%{id: key}`. The wrapper rewrite then bound the canonical name
  around a pattern that rebinds it:

      def via(key = %{id: key})
      ** (CompileError) the variable "key" is defined in function of itself

  which failed to compile at all. The two bindings mean different things — the
  positional argument versus a field inside it — so they cannot share a name.
  The wrapper's binding is the one that moves aside, since the user's pattern and
  guards have to survive verbatim or dispatch changes.

  These fixtures compiling is half the test. The rest is that the user's meaning
  is preserved: guards still test the inner value, and contracts still see the
  positional argument.
  """

  use ExUnit.Case, async: true

  alias BondTest.NameCollision.ListDestructure
  alias BondTest.NameCollision.MapDestructure
  alias BondTest.NameCollision.TupleDestructure
  alias BondTest.NameCollision.WithPostcondition

  describe "a clause destructuring into a sibling's parameter name" do
    test "compiles and dispatches to the destructuring clause" do
      assert MapDestructure.via(%{id: 7}) == {:from_map, 7}
    end

    test "still dispatches to the sibling clause" do
      assert MapDestructure.via("xyz") == {:from_binary, "xyz"}
    end

    test "the guard still tests the INNER value, not the whole argument" do
      # `when is_integer(key)` refers to the destructured field. If the wrapper
      # had rebound `key` to the whole map, this would match and return
      # `{:from_map, "x"}` instead of falling through.
      assert_raise FunctionClauseError, fn -> apply(MapDestructure, :via, [%{id: "x"}]) end
    end

    test "a value matching no clause still raises FunctionClauseError" do
      # Through `apply/3`: a direct call with an argument matching no clause is
      # now (correctly) flagged by the type checker, exactly as it would be for an
      # uncontracted module. See Bond.StacktraceTest for why.
      assert_raise FunctionClauseError, fn -> apply(MapDestructure, :via, [%{other: 1}]) end
    end
  end

  describe "the contract sees the positional argument" do
    test "a precondition naming the collided name reads the whole argument" do
      # `@pre positional: is_map(key) or is_binary(key)` holds for both clauses
      # only if `key` means the positional argument. Were it the inner integer,
      # the map clause would raise a PreconditionError instead of returning.
      assert MapDestructure.via(%{id: 7}) == {:from_map, 7}
      assert MapDestructure.via("xyz") == {:from_binary, "xyz"}
    end

    test "a postcondition naming the collided name reads the whole argument" do
      assert WithPostcondition.size(%{entries: [:a, :b]}) == 2
      assert WithPostcondition.size(3) == 3
    end
  end

  describe "other destructuring shapes" do
    test "tuple destructure" do
      assert TupleDestructure.via({:wrapped, "abc"}) == {:unwrapped, "abc"}
      assert TupleDestructure.via("abc") == {:bare, "abc"}
    end

    test "list destructure" do
      assert ListDestructure.via([1, 2, 3]) == {:head, 1}
      assert ListDestructure.via("abc") == {:bare, "abc"}
    end
  end

  describe "Clauses.binds_below_top_level?/2" do
    alias Bond.Compiler.Clauses

    test "detects a name bound inside a destructure" do
      assert Clauses.binds_below_top_level?(quote(do: %{id: key}), :key)
      assert Clauses.binds_below_top_level?(quote(do: {:wrapped, key}), :key)
      assert Clauses.binds_below_top_level?(quote(do: [key | _rest]), :key)
    end

    test "a bare parameter binds at the top level, not below it" do
      refute Clauses.binds_below_top_level?(quote(do: key), :key)
    end

    test "an unrelated inner name is not a collision" do
      refute Clauses.binds_below_top_level?(quote(do: %{id: other}), :key)
    end
  end
end
