defmodule Bond.Compiler.LinterTest do
  @moduledoc """
  Unit tests for the pure `Bond.Compiler.Linter.check/1` AST analysis behind the assertion
  linter (#52). Each rule is checked for both its true positives and — just as important, since a
  noisy contract linter gets disabled wholesale — its silence on legitimate assertions.
  """

  use ExUnit.Case, async: true

  alias Bond.Compiler.Linter

  # Assert that `quoted` produces exactly one finding, tagged with `rule`, whose message contains
  # each fragment in `fragments`.
  defp assert_finding(quoted, rule, fragments) do
    assert [%{rule: ^rule, message: message}] = Linter.check(quoted)

    for fragment <- List.wrap(fragments) do
      assert message =~ fragment,
             "expected finding message to contain #{inspect(fragment)}, got: #{message}"
    end
  end

  defp refute_findings(quoted) do
    assert Linter.check(quoted) == [],
           "expected no findings for #{Macro.to_string(quoted)}, got: " <>
             inspect(Linter.check(quoted))
  end

  describe "constant assertion (rule A)" do
    test "flags a type-disjoint literal comparison as always false" do
      assert_finding(quote(do: :ok == 200), :constant_assertion, ["is always `false`"])
    end

    test "flags a literal `not in` over a list of map literals as always true" do
      assert_finding(
        quote(do: "x" not in [%{a: 1}, %{b: 2}]),
        :constant_assertion,
        ["is always `true`"]
      )
    end

    test "flags a folded numeric comparison" do
      assert_finding(quote(do: 1 == 1), :constant_assertion, ["is always `true`"])
    end

    test "honours Elixir's cross-type numeric equality (1 == 1.0 is true)" do
      assert_finding(quote(do: 1 == 1.0), :constant_assertion, ["is always `true`"])
    end

    test "stays silent on a genuine comparison against a literal" do
      refute_findings(quote(do: x > 0))
      refute_findings(quote(do: status == 200))
    end

    test "does not flag a constant sub-term of an otherwise-dynamic assertion" do
      # `1 == 1` is constant but the whole expression depends on `x`, so no constant-assertion
      # finding fires (and the self-comparison rule ignores equal literals).
      refute_findings(quote(do: x > 0 and 1 == 1))
    end

    test "does not fold an expression containing a non-whitelisted call" do
      refute_findings(quote(do: String.length("x") == 1))
    end

    test "treats a whitelisted expression that raises as dynamic, not constant" do
      refute_findings(quote(do: 1 / 0 == 0))
    end
  end

  describe "self comparison (rule B)" do
    test "flags `x == x` as always true" do
      assert_finding(quote(do: x == x), :self_comparison, [
        "compares a term with itself",
        "`true`"
      ])
    end

    test "flags `x != x` as always false" do
      assert_finding(quote(do: x != x), :self_comparison, ["`false`"])
    end

    test "flags strict variants `===`/`!==`" do
      assert_finding(quote(do: x === x), :self_comparison, ["`true`"])
      assert_finding(quote(do: x !== x), :self_comparison, ["`false`"])
    end

    test "flags a variable or-ed with its own negation (excluded middle)" do
      assert_finding(quote(do: p or not p), :self_comparison, ["always `true`"])
    end

    test "flags a variable and-ed with its own negation (contradiction)" do
      assert_finding(quote(do: p and not p), :self_comparison, ["always `false`"])
    end

    test "flags an excluded-middle over a pure type guard" do
      assert_finding(quote(do: is_list(x) or not is_list(x)), :self_comparison, ["always `true`"])
    end

    test "flags short-circuit dominance (`true or _`, `_ and false`)" do
      assert_finding(quote(do: true or ready?), :self_comparison, [
        "always `true`",
        "forces the result"
      ])

      assert_finding(quote(do: ready? or true), :self_comparison, ["always `true`"])
      assert_finding(quote(do: false and ready?), :self_comparison, ["always `false`"])
    end

    test "does not double-flag a fully-constant boolean expression (constant-folding's job)" do
      # `true or false` is wholly constant -> a single constant_assertion finding, not also a
      # dominance/tautology finding.
      assert_finding(quote(do: true or false), :constant_assertion, ["always `true`"])
      assert_finding(quote(do: true or not true), :constant_assertion, ["always `true`"])
    end

    test "does not flag an excluded-middle over an impure call" do
      refute_findings(quote(do: f(x) or not f(x)))
    end

    test "stays silent when the two sides are different variables" do
      refute_findings(quote(do: x == y))
    end

    test "does not flag a self-comparison of a function call (not provably pure)" do
      refute_findings(quote(do: f(x) == f(x)))
      refute_findings(quote(do: map.key == map.key))
    end

    test "finds a self-comparison nested inside a larger expression" do
      assert_finding(quote(do: valid? and x == x), :self_comparison, [
        "compares a term with itself"
      ])
    end
  end

  describe "vacuous quantifier (rule C)" do
    test "flags a bare-variable generator with a constant predicate" do
      assert_finding(
        quote(do: forall(x <- items, true)),
        :vacuous_quantifier,
        ["constant predicate", "only tests whether the enumerable is empty"]
      )
    end

    test "flags exists with a constant predicate too" do
      assert_finding(quote(do: exists(x <- items, true)), :vacuous_quantifier, ["exists"])
    end

    test "flags a predicate that never references the bound variable" do
      assert_finding(
        quote(do: forall(x <- items, flag > 0)),
        :vacuous_quantifier,
        ["never references the bound variable `x`"]
      )
    end

    test "does NOT flag a structural generator with a constant predicate (post-#55 shape assertion)" do
      refute_findings(quote(do: forall(%{key: _} <- items, true)))
      refute_findings(quote(do: forall(%{retry: r} <- items, true)))
    end

    test "does not flag a bare-variable generator whose predicate uses the binding" do
      refute_findings(quote(do: forall(x <- items, x > 0)))
      refute_findings(quote(do: exists(u <- users, u.role == :admin)))
    end

    test "does not flag a nested quantifier where the outer binding is unused (conservative)" do
      refute_findings(quote(do: forall(x <- xs, forall(y <- ys, y > 0))))
    end
  end

  test "an ordinary, meaningful assertion produces no findings" do
    refute_findings(quote(do: is_integer(n) and n >= 0))
    refute_findings(quote(do: String.starts_with?(s, "prefix")))
    refute_findings(quote(do: Map.has_key?(m, :id) ~> m.id > 0))
  end
end
