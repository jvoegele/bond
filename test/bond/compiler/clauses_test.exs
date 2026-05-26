defmodule Bond.Compiler.ClausesTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.Clauses

  describe "top_level_names/1" do
    test "extracts the bare variable name from a single bare-var param" do
      params = quote(do: [x])
      assert Clauses.top_level_names(params) == [:x]
    end

    test "extracts names from multiple bare-var params" do
      params = quote(do: [conn, resource, scope])
      assert Clauses.top_level_names(params) == [:conn, :resource, :scope]
    end

    test "extracts the bound name from `pattern = name`" do
      params = quote(do: [%__MODULE__{} = stack, item])
      assert Clauses.top_level_names(params) == [:stack, :item]
    end

    test "extracts the bound name from the reversed `name = pattern`" do
      params = quote(do: [stack = %__MODULE__{}, item])
      assert Clauses.top_level_names(params) == [:stack, :item]
    end

    test "extracts the bound name when destructure-and-bind both appear" do
      params = quote(do: [%__MODULE__{field: x} = stack])
      assert Clauses.top_level_names(params) == [:stack]
    end

    test "returns nil for a destructure-only pattern" do
      params = quote(do: [%__MODULE__{field: x}, item])
      assert Clauses.top_level_names(params) == [nil, :item]
    end

    test "returns nil for a literal pattern" do
      params = quote(do: [0, x])
      assert Clauses.top_level_names(params) == [nil, :x]
    end

    test "returns nil for a wildcard param" do
      params = quote(do: [_, x])
      assert Clauses.top_level_names(params) == [nil, :x]
    end

    test "treats underscore-prefixed names as top-level names (they're bound)" do
      # `_capacity` is a real bound variable that suppresses Elixir's unused-
      # variable warning. It's a top-level name for our purposes.
      params = quote(do: [_capacity])
      assert Clauses.top_level_names(params) == [:_capacity]
    end

    test "returns nil for a list-destructure" do
      params = quote(do: [[h | t]])
      assert Clauses.top_level_names(params) == [nil]
    end

    test "returns nil for a bare param + guard form (the variable is bare so it's the name)" do
      # The guard isn't visible at the param-level — `is_struct(x, __MODULE__)`
      # lives in `clause.guards`, not `clause.params`. So `top_level_names`
      # sees just `x` as the param, which is the top-level name.
      params = quote(do: [x])
      assert Clauses.top_level_names(params) == [:x]
    end

    test "returns [] for empty params" do
      assert Clauses.top_level_names([]) == []
    end
  end

  describe "canonical_names/1" do
    test "single clause: returns its top-level names verbatim" do
      clauses = [[:conn, :resource, :scope]]
      assert Clauses.canonical_names(clauses) == {:ok, [:conn, :resource, :scope]}
    end

    test "two clauses with identical names: returns those names" do
      clauses = [[:conn, :resource, :scope], [:conn, :resource, :scope]]
      assert Clauses.canonical_names(clauses) == {:ok, [:conn, :resource, :scope]}
    end

    test "one naming clause, one wildcard clause: name wins as canonical" do
      clauses = [[:capacity], [nil]]
      assert Clauses.canonical_names(clauses) == {:ok, [:capacity]}
    end

    test "wildcard first, name second: name wins as canonical" do
      clauses = [[nil], [:capacity]]
      assert Clauses.canonical_names(clauses) == {:ok, [:capacity]}
    end

    test "all clauses wildcard at a position: generated name fills in" do
      clauses = [[nil, :x], [nil, :x]]
      assert Clauses.canonical_names(clauses) == {:ok, [:__bond_arg_0__, :x]}
    end

    test "disagreement: error with the position and the conflicting names" do
      clauses = [[:conn, :g, :f], [:conn, :league, :conference]]

      assert {:error, {:disagreement, 1, [:g, :league]}} = Clauses.canonical_names(clauses)
    end

    test "disagreement reports the first conflicting position even if later ones also conflict" do
      clauses = [[:a, :b], [:x, :y]]

      assert {:error, {:disagreement, 0, [:a, :x]}} = Clauses.canonical_names(clauses)
    end

    test "three clauses, all agreeing on names: ok" do
      clauses = [[:capacity], [:capacity], [:capacity]]
      assert Clauses.canonical_names(clauses) == {:ok, [:capacity]}
    end

    test "three clauses, mixed naming and wildcards at the same position: name wins" do
      clauses = [[:capacity], [nil], [:capacity]]
      assert Clauses.canonical_names(clauses) == {:ok, [:capacity]}
    end

    test "three clauses, two distinct names + one wildcard: disagreement (the wildcard doesn't break the tie)" do
      clauses = [[:capacity], [nil], [:size]]

      assert {:error, {:disagreement, 0, [:capacity, :size]}} = Clauses.canonical_names(clauses)
    end

    test "returns ok with [] for an empty list of clauses" do
      assert Clauses.canonical_names([]) == {:ok, []}
    end
  end

  describe "generated_name/1" do
    test "produces a stable `__bond_arg_<idx>__` atom" do
      assert Clauses.generated_name(0) == :__bond_arg_0__
      assert Clauses.generated_name(1) == :__bond_arg_1__
      assert Clauses.generated_name(7) == :__bond_arg_7__
    end
  end
end
