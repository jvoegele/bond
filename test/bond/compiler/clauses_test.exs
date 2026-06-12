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
      assert Clauses.canonical_names(clauses) == {:ok, [:bond_arg_0, :x]}
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
    test "produces a stable `bond_arg_<idx>` atom (no leading underscore)" do
      assert Clauses.generated_name(0) == :bond_arg_0
      assert Clauses.generated_name(1) == :bond_arg_1
      assert Clauses.generated_name(7) == :bond_arg_7
    end
  end

  describe "referenced_param_names/2" do
    test "returns empty set when no assertions are given" do
      clauses = [%{params: quote(do: [x, y])}]
      assert MapSet.size(Clauses.referenced_param_names([], clauses)) == 0
    end

    test "collects a single param name referenced in an assertion" do
      assertions = [%{expression: quote(do: x > 0)}]
      clauses = [%{params: quote(do: [x, y])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.equal?(result, MapSet.new([:x]))
    end

    test "drops `result` (not a top-level param name)" do
      assertions = [%{expression: quote(do: is_boolean(result))}]
      clauses = [%{params: quote(do: [x, y])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.size(result) == 0
    end

    test "drops `subject` (the invariant binding is synthetic, not a top-level name)" do
      assertions = [%{expression: quote(do: subject.x >= 0)}]
      clauses = [%{params: quote(do: [stack])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.size(result) == 0
    end

    test "collects names from inside `old(...)` expressions" do
      assertions = [%{expression: quote(do: result == old(get(agent)) + 1)}]
      clauses = [%{params: quote(do: [agent])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.equal?(result, MapSet.new([:agent]))
    end

    test "collects from a remote-call assertion" do
      assertions = [%{expression: quote(do: String.starts_with?(name, "user-"))}]
      clauses = [%{params: quote(do: [name])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.equal?(result, MapSet.new([:name]))
    end

    test "doesn't treat function-call heads as variables" do
      # `is_boolean` is a function name, not a variable. Only `result` is a
      # var reference. (And `result` isn't a top-level name, so the result
      # is empty.)
      assertions = [%{expression: quote(do: is_boolean(result))}]
      clauses = [%{params: quote(do: [x])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.size(result) == 0
    end

    test "unions references across multiple assertions" do
      assertions = [
        %{expression: quote(do: x > 0)},
        %{expression: quote(do: y >= 0)}
      ]

      clauses = [%{params: quote(do: [x, y, z])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.equal?(result, MapSet.new([:x, :y]))
    end

    test "intersects with the union of top-level names across ALL clauses" do
      # `g` is a top-level name in clause 1 only. `league` in clause 2 only.
      # Both are candidates because the union spans every clause.
      assertions = [%{expression: quote(do: is_atom(g))}]

      clauses = [
        %{params: quote(do: [g])},
        %{params: quote(do: [league])}
      ]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert MapSet.equal?(result, MapSet.new([:g]))
    end

    test "known false positive: closure variable matching a param name is collected" do
      # The AST walker can't distinguish closure scope from outer scope —
      # the `x` inside `fn x -> x > 0 end` is structurally identical to a
      # bare-var reference. If `x` happens to be a param name too, it gets
      # collected (over-strict). Documented behaviour; rename either side.
      assertions = [%{expression: quote(do: Enum.all?(xs, fn x -> x > 0 end))}]
      clauses = [%{params: quote(do: [xs, x])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert :x in result
      assert :xs in result
    end
  end

  describe "assert_clauses_agree!/4 with relaxed mode" do
    test "default :all behaves like the strict 3-arg form (disagreement raises)" do
      clauses = [
        %{params: quote(do: [conn, g])},
        %{params: quote(do: [conn, league])}
      ]

      assert_raise CompileError, fn ->
        Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 2})
      end
    end

    test "empty required_names: disagreeing positions get generated names" do
      clauses = [
        %{params: quote(do: [conn, g])},
        %{params: quote(do: [conn, league])}
      ]

      assert {:ok, [:conn, :bond_arg_1]} =
               Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 2}, MapSet.new())
    end

    test "required_names with a disagreeing name: still raises" do
      clauses = [
        %{params: quote(do: [conn, g])},
        %{params: quote(do: [conn, league])}
      ]

      assert_raise CompileError, ~r/Position 1 disagrees/, fn ->
        Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 2}, MapSet.new([:g]))
      end
    end

    test "required_names containing only an agreeing name: passes" do
      clauses = [
        %{params: quote(do: [conn, g])},
        %{params: quote(do: [conn, league])}
      ]

      # Only `conn` is referenced; `conn` agrees; position 1 disagreement
      # doesn't matter because neither g nor league is in required_names.
      assert {:ok, [:conn, :bond_arg_1]} =
               Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 2}, MapSet.new([:conn]))
    end

    test "required_names with one of the disagreeing names: raises at that position" do
      clauses = [
        %{params: quote(do: [a, b, c])},
        %{params: quote(do: [a, b, d])}
      ]

      # Only position 2 disagrees; `d` is required.
      assert_raise CompileError, ~r/Position 2 disagrees/, fn ->
        Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 3}, MapSet.new([:d]))
      end
    end
  end

  describe "underscore-prefixed name normalization (0.17.3)" do
    test "`_a` and `a` agree at the same position; canonical is the non-underscored form" do
      clauses = [[:a, :b], [:_a, :_b]]
      assert {:ok, [:a, :b]} = Clauses.canonical_names(clauses)
    end

    test "all-underscored agreement: canonical is the non-underscored form" do
      clauses = [[:_a, :_b], [:_a, :_b]]
      assert {:ok, [:a, :b]} = Clauses.canonical_names(clauses)
    end

    test "underscore variant and a different name: still a disagreement" do
      clauses = [[:_capacity], [:size]]

      assert {:error, {:disagreement, 0, _conflicting}} = Clauses.canonical_names(clauses)
    end

    test "bare wildcard `_` (returned as nil) remains distinct from named `_a`" do
      # Wildcards are filtered out as nil before normalization; they adopt
      # the canonical from sibling clauses rather than agreeing with `_a`.
      clauses = [[nil], [:_capacity]]
      assert {:ok, [:capacity]} = Clauses.canonical_names(clauses)
    end

    test "referenced_param_names matches `a` in a contract against `_a` in a clause" do
      assertions = [%{expression: quote(do: is_atom(a))}]
      clauses = [%{params: quote(do: [_a, _b, c])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert :a in result
    end

    test "referenced_param_names matches `_a` in a contract against `a` in a clause" do
      # Less common (contracts rarely use underscored names) but symmetric.
      assertions = [%{expression: quote(do: is_atom(_a))}]
      clauses = [%{params: quote(do: [a])}]

      result = Clauses.referenced_param_names(assertions, clauses)
      assert :_a in result
    end

    test "assert_clauses_agree!: contract on `a` + fallback `_a` clause compiles cleanly" do
      clauses = [
        %{params: quote(do: [a, b, c])},
        %{params: quote(do: [_a, _b, c])}
      ]

      required = MapSet.new([:a])

      assert {:ok, [:a, :b, :c]} =
               Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 3}, required)
    end

    test "assert_clauses_agree!: still raises on truly different names even with `_`" do
      clauses = [
        %{params: quote(do: [_size])},
        %{params: quote(do: [capacity])}
      ]

      assert_raise CompileError, fn ->
        Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 1}, MapSet.new([:capacity]))
      end
    end
  end

  describe "assert_clauses_agree!/3" do
    test "returns canonical names when all clauses agree" do
      clauses = [
        %{params: quote(do: [conn, resource, scope])},
        %{params: quote(do: [conn, resource, scope])}
      ]

      assert {:ok, [:conn, :resource, :scope]} =
               Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 3})
    end

    test "returns canonical names when one clause has wildcards and another has names" do
      clauses = [
        %{params: quote(do: [capacity])},
        %{params: quote(do: [_])}
      ]

      assert {:ok, [:capacity]} = Clauses.assert_clauses_agree!(clauses, __ENV__, {:try_new, 1})
    end

    test "raises CompileError on disagreement, naming the function and position" do
      clauses = [
        %{params: quote(do: [conn, g, f])},
        %{params: quote(do: [conn, league, conference])}
      ]

      assert_raise CompileError, ~r/can_access_conference\?\/3/, fn ->
        Clauses.assert_clauses_agree!(clauses, __ENV__, {:can_access_conference?, 3})
      end
    end

    test "disagreement message names the conflicting position and the names" do
      clauses = [
        %{params: quote(do: [conn, g, f])},
        %{params: quote(do: [conn, league, conference])}
      ]

      error =
        assert_raise CompileError, fn ->
          Clauses.assert_clauses_agree!(clauses, __ENV__, {:can_access_conference?, 3})
        end

      message = Exception.message(error)
      assert message =~ "Position 1 disagrees"
      assert message =~ ":g"
      assert message =~ ":league"
    end

    test "disagreement message includes a per-clause summary" do
      clauses = [
        %{params: quote(do: [a])},
        %{params: quote(do: [b])}
      ]

      error =
        assert_raise CompileError, fn ->
          Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 1})
        end

      message = Exception.message(error)
      assert message =~ "clause 1: a"
      assert message =~ "clause 2: b"
    end

    test "disagreement message points at the consistent-names fix" do
      clauses = [
        %{params: quote(do: [a])},
        %{params: quote(do: [b])}
      ]

      error =
        assert_raise CompileError, fn ->
          Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 1})
        end

      message = Exception.message(error)
      assert message =~ "rename each clause to use one consistent name"
    end

    test "disagreement message mentions ~> for shape-dependent contracts" do
      clauses = [
        %{params: quote(do: [a])},
        %{params: quote(do: [b])}
      ]

      error =
        assert_raise CompileError, fn ->
          Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 1})
        end

      message = Exception.message(error)
      assert message =~ "~>"
    end

    test "single-clause function: trivially agrees" do
      clauses = [%{params: quote(do: [x, y])}]
      assert {:ok, [:x, :y]} = Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 2})
    end

    test "empty params: returns empty canonical list" do
      clauses = [%{params: []}]
      assert {:ok, []} = Clauses.assert_clauses_agree!(clauses, __ENV__, {:f, 0})
    end
  end

  describe "rewrite_clause_params/3" do
    test "leaves a bare-var param matching the canonical alone" do
      params = quote(do: [stack])
      [result] = Clauses.rewrite_clause_params(params, [:stack])
      assert match?({:stack, _, _}, result)
    end

    test "rewrites a wildcard to bind the canonical" do
      params = quote(do: [_])
      [result] = Clauses.rewrite_clause_params(params, [:capacity])
      assert match?({:capacity, _, _}, result)
    end

    test "wraps a destructure-only pattern with `canonical = <pattern>`" do
      params = quote(do: [%BondTest.Mod{f: x}])
      [result] = Clauses.rewrite_clause_params(params, [:state])
      source = Macro.to_string(result)
      assert source =~ ~r/state\s*=\s*%BondTest\.Mod\{/
    end

    test "wraps a literal pattern with `canonical = <pattern>`" do
      params = quote(do: [0])
      [result] = Clauses.rewrite_clause_params(params, [:n])
      source = Macro.to_string(result)
      assert source =~ ~r/n\s*=\s*0/
    end

    test "leaves `pattern = name` matches alone when name is the canonical" do
      params = quote(do: [%BondTest.Mod{} = stack])
      [result] = Clauses.rewrite_clause_params(params, [:stack])
      source = Macro.to_string(result)
      assert source =~ "stack"
      # No double-wrapping like `stack = (%Mod{} = stack)`
      refute source =~ ~r/stack\s*=\s*\(/
    end

    test "underscore-prefixes destructured names other than the canonical" do
      params = quote(do: [%BondTest.Mod{id: id, name: name} = subject])
      [result] = Clauses.rewrite_clause_params(params, [:subject])
      source = Macro.to_string(result)
      assert source =~ "subject"
      assert source =~ "_id"
      assert source =~ "_name"
    end

    test "preserves destructured names that are in the `used` set" do
      params = quote(do: [%BondTest.Mod{count: current_count} = state])

      [result] = Clauses.rewrite_clause_params(params, [:state], MapSet.new([:current_count]))

      source = Macro.to_string(result)
      assert source =~ "current_count"
      refute source =~ "_current_count"
    end

    test "handles multiple positions with different canonical names" do
      params = quote(do: [conn, %BondTest.Mod{} = resource, _])

      [a, b, c] = Clauses.rewrite_clause_params(params, [:conn, :resource, :scope])

      assert match?({:conn, _, _}, a)
      assert Macro.to_string(b) =~ "resource"
      assert match?({:scope, _, _}, c)
    end

    test "generated canonical name (`bond_arg_<idx>`) binds to a no-name position" do
      params = quote(do: [0])
      [result] = Clauses.rewrite_clause_params(params, [:bond_arg_0])
      source = Macro.to_string(result)
      assert source =~ "bond_arg_0"
      assert source =~ "0"
    end

    test "underscore-prefix doesn't touch the canonical even if `used` is empty" do
      # The canonical names are always implicitly "used" — never prefixed.
      params = quote(do: [stack])
      [result] = Clauses.rewrite_clause_params(params, [:stack])
      assert match?({:stack, _, _}, result)
      refute match?({:_stack, _, _}, result)
    end
  end

  describe "guard_var_names/1" do
    test "returns [] for no guards" do
      assert Clauses.guard_var_names([]) == MapSet.new()
    end

    test "collects the variable in a simple guard" do
      guards = quote(do: [is_binary(key)])
      assert Clauses.guard_var_names(guards) == MapSet.new([:key])
    end

    test "collects names across a compound guard" do
      guards = quote(do: [is_integer(capacity) and capacity >= 0])
      assert Clauses.guard_var_names(guards) == MapSet.new([:capacity])
    end

    test "collects a destructured field name referenced by the guard" do
      guards = quote(do: [n > 10])
      assert Clauses.guard_var_names(guards) == MapSet.new([:n])
    end

    test "collects across multiple `when ... when ...` guards" do
      guards = quote(do: [is_atom(x), is_struct(y, Foo)])
      assert Clauses.guard_var_names(guards) == MapSet.new([:x, :y])
    end

    test "does not collect remote-call heads or function names as variables" do
      guards = quote(do: [String.length(resource) > 0])
      assert Clauses.guard_var_names(guards) == MapSet.new([:resource])
    end
  end

  describe "expression_var_names/1" do
    test "collects every bare variable in an ordinary expression" do
      expr = quote(do: balance + fee >= 0)
      assert Clauses.expression_var_names(expr) == MapSet.new([:balance, :fee])
    end

    test "excludes a name bound by a `<~` pattern, keeps the matched-against name" do
      expr = quote(do: {:ok, value} <~ result)
      assert Clauses.expression_var_names(expr) == MapSet.new([:result])
    end

    test "excludes a `<~` pattern binding referenced by its own `when` guard" do
      expr = quote(do: ({:ok, path} when is_binary(path)) <~ result)
      assert Clauses.expression_var_names(expr) == MapSet.new([:result])
    end

    test "keeps a `when` guard reference to an outer name while excluding the pattern binding" do
      expr = quote(do: ({:ok, v} when v > limit) <~ result)
      assert Clauses.expression_var_names(expr) == MapSet.new([:limit, :result])
    end

    test "treats a pinned `^var` in a `<~` pattern as a free reference, not a binding" do
      expr = quote(do: ^expected <~ result)
      assert Clauses.expression_var_names(expr) == MapSet.new([:expected, :result])
    end

    test "finds bindings in a `<~` nested inside a `~>` implication" do
      expr = quote(do: ok? ~> ({:ok, value} <~ result))
      assert Clauses.expression_var_names(expr) == MapSet.new([:ok?, :result])
    end

    test "combines free names across the matched expression and the rest of the assertion" do
      expr = quote(do: {:ok, value} <~ run(input) and result == fallback)
      assert Clauses.expression_var_names(expr) == MapSet.new([:input, :result, :fallback])
    end
  end

  describe "underscore_prefix_unused/2" do
    test "leaves a bare variable alone when it's in the used set" do
      pattern = quote(do: x)
      assert match?({:x, _, _}, Clauses.underscore_prefix_unused(pattern, [:x]))
    end

    test "underscore-prefixes a bare variable not in the used set" do
      pattern = quote(do: x)
      result = Clauses.underscore_prefix_unused(pattern, [])
      assert match?({:_x, _, _}, result)
    end

    test "leaves a wildcard `_` alone" do
      pattern = quote(do: _)
      assert match?({:_, _, _}, Clauses.underscore_prefix_unused(pattern, []))
    end

    test "leaves an already-prefixed `_foo` alone (no double-prefix)" do
      pattern = quote(do: _foo)
      assert match?({:_foo, _, _}, Clauses.underscore_prefix_unused(pattern, []))
    end

    test "handles `pattern = name` matches: bound name on the right" do
      pattern = quote(do: %{f: x} = state)
      # `state` is used; `x` isn't.
      result = Clauses.underscore_prefix_unused(pattern, [:state])
      source = Macro.to_string(result)
      assert source =~ "_x"
      assert source =~ "state"
      refute source =~ ~r/(?<![_a-z])x[^a-z_]/
    end

    test "handles `name = pattern` matches: bound name on the left" do
      pattern = quote(do: state = %{f: x})
      result = Clauses.underscore_prefix_unused(pattern, [:state])
      source = Macro.to_string(result)
      assert source =~ "_x"
      assert source =~ "state"
    end

    test "underscore-prefixes destructured names inside a struct pattern" do
      pattern = quote(do: %BondTest.Mod{id: id, name: name} = subject)
      # Only `subject` is referenced.
      result = Clauses.underscore_prefix_unused(pattern, [:subject])
      source = Macro.to_string(result)
      assert source =~ "_id"
      assert source =~ "_name"
      assert source =~ "subject"
    end

    test "preserves destructured names that are in the used set" do
      pattern = quote(do: %BondTest.Mod{count: current_count} = subject)
      result = Clauses.underscore_prefix_unused(pattern, [:subject, :current_count])
      source = Macro.to_string(result)
      assert source =~ "current_count"
      refute source =~ "_current_count"
    end

    test "underscore-prefixes inside a list destructure" do
      pattern = quote(do: [head | tail])
      result = Clauses.underscore_prefix_unused(pattern, [:head])
      source = Macro.to_string(result)
      assert source =~ "head"
      assert source =~ "_tail"
    end

    test "doesn't rewrite pinned variables (they're uses, not bindings)" do
      pattern = quote(do: {:ok, ^expected})
      result = Clauses.underscore_prefix_unused(pattern, [])
      source = Macro.to_string(result)
      # `expected` is pinned — it's a use of a value, not a binding. Must not
      # rename it; doing so would change which variable is being referenced.
      assert source =~ "^expected"
      refute source =~ "_expected"
    end

    test "underscore-prefixes inside a tuple pattern" do
      pattern = quote(do: {:ok, payload})
      result = Clauses.underscore_prefix_unused(pattern, [])
      source = Macro.to_string(result)
      assert source =~ "_payload"
    end

    test "underscore-prefixes inside nested destructures" do
      pattern = quote(do: %Outer{inner: %Inner{value: v} = inner_struct} = full)
      result = Clauses.underscore_prefix_unused(pattern, [:full])
      source = Macro.to_string(result)
      assert source =~ "_v"
      assert source =~ "_inner_struct"
      assert source =~ "full"
    end

    test "accepts a MapSet for the used set" do
      pattern = quote(do: x)
      result = Clauses.underscore_prefix_unused(pattern, MapSet.new([:x]))
      assert match?({:x, _, _}, result)
    end

    test "accepts a list for the used set" do
      pattern = quote(do: x)
      result = Clauses.underscore_prefix_unused(pattern, [:x])
      assert match?({:x, _, _}, result)
    end
  end
end
