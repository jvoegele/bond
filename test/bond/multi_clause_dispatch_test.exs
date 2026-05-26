defmodule Bond.MultiClauseDispatchTest do
  @moduledoc """
  End-to-end behavioural tests for 0.17.0's per-clause wrapper emission.
  Drives the `BondTest.MultiClauseDispatch` fixture through shape-dispatching
  multi-clause functions, wildcard-adopts-canonical clauses, destructure-in-
  head patterns, and 3-clause dispatch.

  Plus compile-time validation tests confirming that heterogeneous top-level
  names raise a clear `CompileError` rather than producing a wrapper-head
  shape leak.
  """

  use ExUnit.Case
  use Bond.Test

  alias BondTest.MultiClauseDispatch, as: Fix

  describe "multi-clause function with shape-dispatching clauses" do
    test "struct clause matches a struct input and contract passes" do
      result = Fix.lookup(:conn, %Fix{id: 5, tag: :foo})
      assert {:ok, :conn, %Fix{id: 5}} = result
    end

    test "string clause matches a string input and contract passes" do
      assert {:string, :conn, "abc"} = Fix.lookup(:conn, "abc")
    end

    test "implication contract fires for the struct clause when consequent fails" do
      # Struct with non-positive id; first implication's consequent fails.
      assert_precondition_violation(Fix.lookup(:conn, %Fix{id: -1, tag: :foo}),
        expression: ~r/resource\.id > 0/
      )
    end

    test "implication contract fires for the string clause when consequent fails" do
      assert_precondition_violation(Fix.lookup(:conn, ""),
        expression: ~r/String\.length/
      )
    end

    test "non-matching shape (neither struct nor binary) raises FunctionClauseError" do
      # 42 is neither a Fix struct nor a binary — no user clause matches.
      assert_raise FunctionClauseError, fn -> Fix.lookup(:conn, 42) end
    end
  end

  describe "wildcard-adopts-canonical multi-clause function" do
    test "integer input dispatches to the typed clause" do
      assert {:ok, %{capacity: 3}} = Fix.try_init(3)
    end

    test "non-integer input dispatches to the wildcard clause" do
      # Clause 2's `_` adopts the canonical name `capacity`. Bond's wrapper
      # rewrites `def try_init(_)` to `def try_init(capacity)`, then super
      # dispatches to the user's clauses by their original guards.
      assert {:error, :invalid_capacity} = Fix.try_init(:not_an_integer)
    end

    test "negative integer fails the implication contract" do
      assert_precondition_violation(Fix.try_init(-1), expression: ~r/capacity >= 0/)
    end
  end

  describe "destructure-in-head pattern with multi-clause dispatch" do
    test "list with a matching first element returns that element" do
      assert :a = Fix.parse([:a, :b])
    end

    test "list with non-matching first element falls through to the second clause" do
      # Clause 1's guard `first in [:a, :b, :c]` fails for `:x`; Elixir
      # dispatches to clause 2 via super.
      assert :unknown = Fix.parse([:x, :y])
    end

    test "empty list dispatches to the wildcard list clause" do
      assert :unknown = Fix.parse([])
    end

    test "non-list raises PreconditionError from the universal @pre" do
      assert_precondition_violation(Fix.parse(42), expression: ~r/is_list/)
    end
  end

  describe "three-clause dispatch with consistent naming" do
    test "empty-list clause prepends" do
      item = %Fix{id: 1, tag: :a}
      assert [^item] = Fix.concat_or_pass([], item)
    end

    test "non-empty-list clause appends" do
      item = %Fix{id: 2, tag: :b}
      assert [:existing, ^item] = Fix.concat_or_pass([:existing], item)
    end

    test "implication contract fires when struct item has nil id" do
      assert_precondition_violation(
        Fix.concat_or_pass([], %Fix{id: nil, tag: :bad}),
        expression: ~r/item\.id != nil/
      )
    end

    test "non-struct item bypasses the implication contract (antecedent false)" do
      # `is_struct(item, __MODULE__) ~> ...` shortcircuits when the item
      # isn't a Fix struct, so passing a plain atom is fine.
      assert [:existing, :tag] = Fix.concat_or_pass([:existing], :tag)
    end
  end

  describe "compile-time validator: heterogeneous top-level names" do
    test "raises CompileError pointing at the canonical fix" do
      code = """
      defmodule Bond.MultiClauseDispatchTest.HeterogeneousNames do
        use Bond

        @pre conn != nil
        def lookup(conn, g, f) when is_atom(g), do: {conn, g, f}
        def lookup(conn, league, conference) when is_binary(league), do: {conn, league, conference}
      end
      """

      assert_raise CompileError, ~r/Bond requires consistent top-level parameter names/, fn ->
        Code.eval_string(code)
      end
    end

    test "error message includes the function name, position, and conflicting names" do
      code = """
      defmodule Bond.MultiClauseDispatchTest.HetNamesDetail do
        use Bond

        @pre conn != nil
        def lookup(conn, g, f) when is_atom(g), do: {conn, g, f}
        def lookup(conn, league, conference) when is_binary(league), do: {conn, league, conference}
      end
      """

      error =
        assert_raise CompileError, fn ->
          Code.eval_string(code)
        end

      message = Exception.message(error)
      assert message =~ "lookup/3"
      assert message =~ "Position 1 disagrees"
      assert message =~ ":g"
      assert message =~ ":league"
    end

    test "error message suggests ~> for shape-dependent assertions" do
      code = """
      defmodule Bond.MultiClauseDispatchTest.HetNamesHint do
        use Bond

        @pre x != nil
        def f(x), do: x
        def f(y), do: y
      end
      """

      error =
        assert_raise CompileError, fn ->
          Code.eval_string(code)
        end

      assert Exception.message(error) =~ "~>"
    end
  end

  describe "regression: no destructure-in-head warning leakage" do
    test "destructured names in wrapper are underscore-prefixed (no warning fired)" do
      # The `parse([first | rest])` clause has destructured names that the
      # wrapper body doesn't reference. Bond's rewrite underscores them in
      # the wrapper pattern; the lifted defp's pattern keeps them for
      # contract access. The CaptureIO check below confirms no warning fires
      # when the fixture compiles.
      # The fixture's user def uses both `first` and `rest` in its body so any
      # remaining "unused" warning would come from Bond's wrapper, not the
      # user's clause. Pre-0.17.0, Bond duplicated the destructure pattern in
      # the wrapper head without underscore-prefixing — emitting the warning.
      # 0.17.0's rewrite suppresses it.
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.eval_string("""
          defmodule Bond.MultiClauseDispatchTest.DestructureFixture do
            use Bond

            @pre is_list(items)
            def head([first | rest]) when first != nil, do: {first, rest}
            def head(items) when is_list(items), do: nil
          end
          """)
        end)

      refute output =~ ~r/variable "first" is unused/,
             "expected no 'first is unused' warning, got:\n#{output}"

      refute output =~ ~r/variable "rest" is unused/,
             "expected no 'rest is unused' warning, got:\n#{output}"
    end
  end
end
