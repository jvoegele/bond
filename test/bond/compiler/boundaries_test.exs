defmodule Bond.Compiler.BoundariesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Bond.Compiler.Boundaries

  doctest Boundaries

  describe "extract/2 — single comparison against a literal" do
    test "maps `arg >= n` to the arg's index with straddling candidates" do
      assert Boundaries.extract([quote(do: x >= 0)], [:x]) == %{0 => [-1, 0, 1]}
    end

    test "strict `>` produces the same candidates (the @pre filter discards the invalid one)" do
      assert Boundaries.extract([quote(do: x > 0)], [:x]) == %{0 => [-1, 0, 1]}
    end

    test "`<=` against a non-zero literal" do
      assert Boundaries.extract([quote(do: n <= 10)], [:n]) == %{0 => [9, 10, 11]}
    end

    test "`==` and `!=` are treated uniformly as boundaries" do
      assert Boundaries.extract([quote(do: x == 5)], [:x]) == %{0 => [4, 5, 6]}
      assert Boundaries.extract([quote(do: x != 5)], [:x]) == %{0 => [4, 5, 6]}
    end

    test "the literal may appear on either side of the operator" do
      mirrored = Boundaries.extract([quote(do: 0 <= x)], [:x])
      assert mirrored == %{0 => [-1, 0, 1]}
    end

    test "negative literals (unary minus) are recognised" do
      assert Boundaries.extract([quote(do: x >= -5)], [:x]) == %{0 => [-6, -5, -4]}
    end

    test "float literals yield float candidates" do
      assert Boundaries.extract([quote(do: temp >= 0.0)], [:temp]) == %{0 => [-1.0, 0.0, 1.0]}
    end
  end

  describe "extract/2 — argument positioning" do
    test "maps to the correct positional index in a multi-arg function" do
      assert Boundaries.extract([quote(do: amount >= 1)], [:account, :amount]) == %{
               1 => [0, 1, 2]
             }
    end

    test "arguments with no literal boundary are absent from the map" do
      assert Boundaries.extract([quote(do: amount >= 0)], [:account, :amount]) == %{
               1 => [-1, 0, 1]
             }
    end

    test "empty precondition list yields an empty map" do
      assert Boundaries.extract([], [:x, :y]) == %{}
    end
  end

  describe "extract/2 — nested and multiple comparisons" do
    test "finds comparisons nested inside `and`" do
      expr = quote(do: is_integer(x) and x <= 10)
      assert Boundaries.extract([expr], [:x]) == %{0 => [9, 10, 11]}
    end

    test "finds comparisons nested inside an implication (`~>`)" do
      # `~>` binds tighter than the comparison operators (see Bond.Predicates docs), so a
      # comparison consequent must be parenthesised — `a ~> (b > c)`, not `a ~> b > c`.
      expr = quote(do: is_integer(x) ~> (x > 0))
      assert Boundaries.extract([expr], [:x]) == %{0 => [-1, 0, 1]}
    end

    test "merges candidates from two comparisons on the same argument, sorted and deduped" do
      expr = quote(do: x >= 0 and x <= 100)
      assert Boundaries.extract([expr], [:x]) == %{0 => [-1, 0, 1, 99, 100, 101]}
    end

    test "combines candidates across separate precondition expressions" do
      exprs = [quote(do: x >= 0), quote(do: y <= 10)]
      assert Boundaries.extract(exprs, [:x, :y]) == %{0 => [-1, 0, 1], 1 => [9, 10, 11]}
    end
  end

  describe "extract/2 — `in range`" do
    test "injects candidates straddling both ends of a literal range" do
      assert Boundaries.extract([quote(do: x in 1..10)], [:x]) ==
               %{0 => [0, 1, 2, 9, 10, 11]}
    end
  end

  describe "extract/2 — size/length-wrapper boundaries (#43)" do
    test "`length(arg) <= n` yields straddling size probes for that arg" do
      assert Boundaries.extract([quote(do: length(items) <= 3)], [:items]) == %{
               0 => [{:size, :length, 2}, {:size, :length, 3}, {:size, :length, 4}]
             }
    end

    test "candidate sizes are clamped to non-negative (no size -1)" do
      assert Boundaries.extract([quote(do: byte_size(s) > 0)], [:s]) == %{
               0 => [{:size, :byte_size, 0}, {:size, :byte_size, 1}]
             }
    end

    test "all four Kernel size wrappers are recognised" do
      assert Boundaries.extract([quote(do: tuple_size(t) == 3)], [:t]) == %{
               0 => [{:size, :tuple_size, 2}, {:size, :tuple_size, 3}, {:size, :tuple_size, 4}]
             }

      assert Boundaries.extract([quote(do: map_size(m) >= 1)], [:m]) == %{
               0 => [{:size, :map_size, 0}, {:size, :map_size, 1}, {:size, :map_size, 2}]
             }
    end

    test "the wrapper may appear on either side of the operator" do
      assert Boundaries.extract([quote(do: 3 >= length(items))], [:items]) == %{
               0 => [{:size, :length, 2}, {:size, :length, 3}, {:size, :length, 4}]
             }
    end

    test "maps to the correct positional index in a multi-arg function" do
      assert Boundaries.extract([quote(do: length(items) <= 2)], [:acc, :items]) == %{
               1 => [{:size, :length, 1}, {:size, :length, 2}, {:size, :length, 3}]
             }
    end

    test "a wrapper over a derived expression is not recognised (filter-only)" do
      assert Boundaries.extract([quote(do: length(tl(items)) <= 3)], [:items]) == %{}
    end
  end

  describe "extract/2 — intentionally skipped forms (filter-only)" do
    test "relational comparison (arg vs field access) yields no candidates" do
      expr = quote(do: amount <= account.balance)
      assert Boundaries.extract([expr], [:amount, :account]) == %{}
    end

    test "relational comparison (arg vs arg) yields no candidates" do
      expr = quote(do: lo <= hi)
      assert Boundaries.extract([expr], [:lo, :hi]) == %{}
    end

    test "comparison between two literals yields no candidates" do
      assert Boundaries.extract([quote(do: 5 >= 3)], [:x]) == %{}
    end

    test "comparison against a non-numeric literal yields no candidates" do
      assert Boundaries.extract([quote(do: name == "admin")], [:name]) == %{}
    end
  end
end
