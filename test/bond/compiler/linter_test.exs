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

    # An always-FALSE assertion fails on every call; an always-TRUE one can never fail. Those are
    # opposite defects, and a single shared message described both as "can never fail" — telling a
    # reader of the always-false case the exact opposite of what their contract does.
    test "describes an always-false assertion as failing on every call" do
      assert_finding(
        quote(do: :ok == 200),
        :constant_assertion,
        ["fails on every call", "can never be satisfied"]
      )

      refute Linter.check(quote(do: :ok == 200))
             |> hd()
             |> Map.fetch!(:message) =~ "can never fail"
    end

    test "describes an always-true assertion as never failing" do
      assert_finding(
        quote(do: 1 == 1),
        :constant_assertion,
        ["can never fail and so asserts nothing"]
      )
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

    # Same defect as the constant-assertion rule had: the always-true and always-false cases share
    # a message, and describing an always-false assertion as one that "asserts nothing" is
    # backwards — it rejects every input rather than accepting every input.
    test "distinguishes an always-false dominance from an always-true one" do
      assert_finding(quote(do: false and ready?), :self_comparison, ["fails on every call"])
      assert_finding(quote(do: true or ready?), :self_comparison, ["asserts nothing"])
    end

    test "distinguishes an always-false negation pair from an always-true one" do
      assert_finding(quote(do: ready? and not ready?), :self_comparison, [
        "always `false`",
        "own negation",
        "fails on every call"
      ])

      assert_finding(quote(do: ready? or not ready?), :self_comparison, [
        "always `true`",
        "own negation",
        "asserts nothing"
      ])
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

    # Parenthesised deliberately. This line read `Map.has_key?(m, :id) ~> m.id > 0` until the
    # `:implication_precedence` rule flagged it (#133): `~>` binds tighter than `>`, so it parsed
    # as `(Map.has_key?(m, :id) ~> m.id) > 0` — always true, asserting nothing, in a test whose
    # name calls it meaningful. A fourth place Bond shipped this mistake, after the guide, the
    # `Bond.Predicates` moduledoc and a compile error's suggested fix.
    refute_findings(quote(do: Map.has_key?(m, :id) ~> (m.id > 0)))
  end

  describe "implication precedence (#133)" do
    test "flags an ordering comparison whose operand is an implication" do
      assert [%{rule: :implication_precedence}] =
               Linter.check(quote(do: is_binary(x) ~> String.length(x) <= 10))
    end

    test "names the parse, the constant it folds to, and the fix" do
      [%{message: message}] = Linter.check(quote(do: is_binary(x) ~> String.length(x) <= 10))

      assert message =~ "parses as `(is_binary(x) ~> String.length(x)) <= 10`"
      assert message =~ "always `false`"
      assert message =~ "fails on every call"
      assert message =~ "`is_binary(x) ~> (String.length(x) <= 10)`"
    end

    test "the >= form is always true and says so" do
      [%{message: message}] = Linter.check(quote(do: is_binary(x) ~> String.length(x) >= 0))

      assert message =~ "always `true`"
      assert message =~ "asserts nothing"
    end

    test "omits the constant claim when the other operand is not a literal" do
      [%{message: message}] = Linter.check(quote(do: is_binary(x) ~> String.length(x) <= limit))

      refute message =~ "always"
      assert message =~ "Parenthesise the consequent"
    end

    test "fires when the implication is on the right of the comparison" do
      assert [%{rule: :implication_precedence}] =
               Linter.check(quote(do: 0 <= is_binary(x) ~> String.length(x)))
    end

    test "finds it inside a quantifier predicate" do
      assert [%{rule: :implication_precedence}] =
               Linter.check(quote(do: forall(e <- es, match?(%{retry: _}, e) ~> e.retry >= 0)))
    end

    test "stays silent on the parenthesised form" do
      refute_findings(quote(do: is_binary(x) ~> (String.length(x) <= 10)))
      refute_findings(quote(do: forall(e <- es, match?(%{retry: _}, e) ~> (e.retry >= 0))))
    end

    test "stays silent on a comparison with no implication" do
      refute_findings(quote(do: String.length(x) <= 10))
    end

    test "stays silent on equality against an implication, which could be deliberate" do
      refute_findings(quote(do: is_binary(x) ~> y == true))
      refute_findings(quote(do: is_binary(x) ~> y != false))
    end
  end
end
