defmodule Bond.Compiler.Linter do
  @moduledoc internal: true

  @moduledoc """
  Compile-time linter for assertion expressions (#52).

  A contract's whole value is that it *can* fail on bad behaviour; an assertion that is
  statically always true (or always constant) protects nothing yet reads as coverage — worse
  than no contract at all. This module walks the assertion AST that Bond already builds and
  emits high-confidence "this assertion probably doesn't mean what you think" warnings for a
  small, deliberately narrow ruleset.

  `check/1` is a pure function returning a list of `t:finding/0` — it does no I/O, so it is
  unit-testable in isolation. `warn/2` runs `check/1` and emits each finding through `IO.warn/2`
  (carrying the assertion's file/line, and honouring `--warnings-as-errors`); it is called from
  `Bond.Compiler.Assertion.new/5`, guarded by the `:lint_assertions` compile-time config.

  ## Ruleset

  Every rule is *structural* (no type inference) and fires only where the shape is wrong by
  construction — when in doubt, it stays silent, because a noisy contract linter gets disabled
  wholesale. Most rules prove a constant *value*; the precedence rule proves a constant *parse*,
  which is why it can fire where the resulting constant cannot be named.

    * **Constant assertion** — the whole expression folds to a constant over literals and pure
      comparison/boolean/arithmetic operators (`:ok == 200`, `"x" not in [%{...}]`, `1 == 1`).
      Only the *entire* assertion is flagged; a constant sub-term (`x > 0 and 1 == 1`) is not.
    * **Self comparison** — `E == E`/`E === E` (always true), `E != E`/`E !== E` (always false),
      `E or not E` (always true), `E and not E` (always false), where `E` is a variable or
      literal (calls and field access are excluded, since `f() == f()` need not be constant).
    * **Vacuous quantifier** — a `forall`/`exists` whose generator is a **bare variable** and
      whose predicate is either constant or ignores the bound variable, so the quantifier only
      tests whether the enumerable is empty. A *structural* generator is never flagged: since
      #55 it asserts the shape of every element, which is a real check.
    * **Implication precedence** — an ordering comparison (`<`, `>`, `<=`, `>=`) one of whose
      operands is a `~>`. `~>` is in Elixir's arrow group and binds tighter than every
      comparison, so `p ~> q >= 0` parses as `(p ~> q) >= 0` and is constant. Equality operators
      are excluded: `(p ~> q) == true` is odd but could be deliberate.
  """

  @typedoc """
  A single lint finding: `:rule` identifies which rule fired; `:message` is the human-readable
  diagnostic (already including the offending code).
  """
  @type finding :: %{
          rule:
            :constant_assertion
            | :self_comparison
            | :vacuous_quantifier
            | :implication_precedence,
          message: String.t()
        }

  # Operators over which a fully-literal expression may be safely constant-folded. All are pure
  # Kernel comparison/boolean/arithmetic operators, so evaluating a node whose every leaf is a
  # literal has no side effects.
  @const_ops [
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :in,
    :and,
    :or,
    :not,
    :&&,
    :||,
    :!,
    :+,
    :-,
    :*,
    :/,
    :div,
    :rem,
    :abs
  ]

  @quantifiers [:forall, :exists]

  # Ordering comparisons only. `==`/`!=`/`===`/`!==` against an implication are odd but could be
  # deliberate, and this rule's bar is no false positives (#133).
  @ordering_comparisons [:<, :>, :<=, :>=]

  @doc """
  Analyses an assertion `expression` and returns a (possibly empty) list of `t:finding/0`.

  Pure — performs no I/O. `warn/2` is the side-effecting counterpart used by the compiler.
  """
  @spec check(Macro.t()) :: [finding()]
  def check(expression) do
    Enum.concat([
      constant_assertion(expression),
      self_comparisons(expression),
      vacuous_quantifiers(expression),
      implication_precedence(expression)
    ])
  end

  @doc """
  Runs `check/1` on `expression` and emits each finding via `IO.warn/2`, anchored at `env`'s
  file/line. Returns `:ok`.
  """
  @spec warn(Macro.t(), Macro.Env.t()) :: :ok
  def warn(expression, %Macro.Env{} = env) do
    for %{message: message} <- check(expression) do
      IO.warn(message, env)
    end

    :ok
  end

  # --- Rule: constant assertion ---------------------------------------------------------------

  # Fires only when the WHOLE assertion folds to a constant (not merely a constant sub-term), so
  # `x > 0 and 1 == 1` is left alone while `1 == 1` and `:ok == 200` are flagged.
  defp constant_assertion(expression) do
    case constant_value(expression) do
      {:ok, value} ->
        [
          %{
            rule: :constant_assertion,
            message:
              "Bond assertion linter: `#{Macro.to_string(expression)}` is always " <>
                "`#{inspect(value)}` — #{constant_consequence(value)} Compare values " <>
                "that could actually differ, or remove the assertion."
          }
        ]

      :dynamic ->
        []
    end
  end

  # The two constants are opposite defects and want opposite descriptions. An always-truthy
  # assertion can never fail, so it protects nothing while reading as coverage. An always-falsy
  # one fails on every call instead — the function is unusable rather than unguarded, which is
  # the reverse of "asserts nothing".
  defp constant_consequence(value) when value in [false, nil],
    do: "it fails on every call, so the contract can never be satisfied."

  defp constant_consequence(_truthy),
    do: "it can never fail and so asserts nothing."

  # --- Rule: self comparison ------------------------------------------------------------------

  defp self_comparisons(expression) do
    expression
    |> collect(&self_comparison_finding/1)
    |> Enum.reverse()
  end

  defp self_comparison_finding({op, _, [a, b]}) when op in [:==, :===] do
    if identical?(a, b), do: self_compare_msg(op, a, b, true)
  end

  defp self_comparison_finding({op, _, [a, b]}) when op in [:!=, :!==] do
    if identical?(a, b), do: self_compare_msg(op, a, b, false)
  end

  # `true or _` / `_ or true` (constant regardless of the other operand), or `p or not p`.
  defp self_comparison_finding({:or, _, [a, b]} = node) do
    cond do
      dominant?(a, b, true) or dominant?(b, a, true) -> dominance_msg(node, true)
      negation_pair?(a, b) -> negation_pair_msg(node, true)
      true -> nil
    end
  end

  # `false and _` / `_ and false`, or `p and not p`.
  defp self_comparison_finding({:and, _, [a, b]} = node) do
    cond do
      dominant?(a, b, false) or dominant?(b, a, false) -> dominance_msg(node, false)
      negation_pair?(a, b) -> negation_pair_msg(node, false)
      true -> nil
    end
  end

  defp self_comparison_finding(_), do: nil

  defp self_compare_msg(op, a, b, value) do
    code = Macro.to_string({op, [], [a, b]})

    %{
      rule: :self_comparison,
      message:
        "Bond assertion linter: `#{code}` compares a term with itself and is always " <>
          "`#{value}` — did you mean to compare two different values?"
    }
  end

  defp dominance_msg(node, value) do
    %{
      rule: :self_comparison,
      message:
        "Bond assertion linter: `#{Macro.to_string(node)}` is always `#{value}` — one operand " <>
          "forces the result regardless of the other, so #{constant_effect(value)}"
    }
  end

  # Covers both `p or not p` (always true) and `p and not p` (always false), so it cannot call
  # either one a tautology.
  defp negation_pair_msg(node, value) do
    %{
      rule: :self_comparison,
      message:
        "Bond assertion linter: `#{Macro.to_string(node)}` is always `#{value}` (a term " <>
          "combined with its own negation) — #{constant_effect(value)}"
    }
  end

  # The clause-length form of `constant_consequence/1` above, for messages that have already
  # explained *why* the expression is constant and only need to say what that costs.
  defp constant_effect(value) when value in [false, nil], do: "it fails on every call."
  defp constant_effect(_truthy), do: "it asserts nothing."

  # --- Rule: vacuous quantifier ---------------------------------------------------------------

  defp vacuous_quantifiers(expression) do
    expression
    |> collect(&vacuous_quantifier_finding/1)
    |> Enum.reverse()
  end

  defp vacuous_quantifier_finding({q, _, [{:<-, _, [pattern, _enum]}, predicate]} = node)
       when q in @quantifiers do
    with true <- bare_var?(pattern),
         name = elem(pattern, 0),
         reason when is_binary(reason) <- vacuity_reason(predicate, name) do
      %{
        rule: :vacuous_quantifier,
        message:
          "Bond assertion linter: `#{Macro.to_string(node)}` #{reason}, so the `#{q}` only " <>
            "tests whether the enumerable is empty. Reference the bound element in the " <>
            "predicate, or drop the quantifier."
      }
    else
      _ -> nil
    end
  end

  defp vacuous_quantifier_finding(_), do: nil

  # Returns a reason string when the predicate makes the quantifier vacuous, else nil.
  defp vacuity_reason(predicate, name) do
    case constant_value(predicate) do
      {:ok, value} ->
        "has a constant predicate (`#{inspect(value)}`)"

      :dynamic ->
        if no_quantifier?(predicate) and not references_var?(predicate, name) do
          "has a predicate that never references the bound variable `#{name}`"
        end
    end
  end

  # --- Constant folding -----------------------------------------------------------------------

  # `{:ok, value}` when `ast` is composed solely of literals and whitelisted pure operators (so
  # evaluation is side-effect-free); `:dynamic` otherwise. A whitelisted expression that raises
  # when evaluated (e.g. `1 / 0`) is treated as `:dynamic` — we only claim constancy we can prove.
  @spec constant_value(Macro.t()) :: {:ok, term()} | :dynamic
  defp constant_value(ast) do
    if pure_constant_expr?(ast) do
      try do
        {value, _binding} = Code.eval_quoted(ast)
        {:ok, value}
      rescue
        _ -> :dynamic
      end
    else
      :dynamic
    end
  end

  defp pure_constant_expr?(ast) do
    cond do
      Macro.quoted_literal?(ast) ->
        true

      match?({op, _meta, args} when is_atom(op) and is_list(args), ast) ->
        {op, _meta, args} = ast
        op in @const_ops and Enum.all?(args, &pure_constant_expr?/1)

      true ->
        false
    end
  end

  # --- AST helpers ----------------------------------------------------------------------------

  # A bare variable AST node: `{name, meta, context}` with atom name and atom context (covers
  # `x`, `_`, `_foo`). Anything else — map/tuple/list/pinned/literal pattern — is structural.
  defp bare_var?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp bare_var?(_), do: false

  # Type/introspection guards and destructuring built-ins that are side-effect-free, so an
  # expression built only from them (plus variables, literals, and `@const_ops`) yields the same
  # value every time it is evaluated. Arbitrary function calls and field access (`f()`, `map.key`)
  # are deliberately excluded — `f() == f()` need not be constant.
  @pure_ops [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_tuple,
    :tuple_size,
    :map_size,
    :byte_size,
    :bit_size,
    :length,
    :hd,
    :tl,
    :elem
  ]

  # Two operands are "identical" for self-comparison when they are structurally equal (ignoring
  # metadata) AND deterministic, so both sides must evaluate to the same value. Equal *literals*
  # (`1 == 1`) are left to the constant-folding rule so a term isn't double-flagged.
  defp identical?(a, b) do
    not Macro.quoted_literal?(a) and deterministic?(a) and ast_equal?(a, b)
  end

  # `a` and `b` form a proposition/negation pair — `p` and `not p` — with a deterministic,
  # non-literal `p` (a fully-literal pair is left to the constant-folding rule).
  defp negation_pair?({:not, _, [a]}, b), do: identical?(a, b)
  defp negation_pair?(a, {:not, _, [b]}), do: identical?(a, b)
  defp negation_pair?(_a, _b), do: false

  # `dominant?/3`: `operand` alone forces an `and`/`or` to `value`, and the `other` operand is not
  # itself constant (that whole-constant case is the constant-folding rule's job, not this one).
  defp dominant?(operand, other, value) do
    constant_value(operand) == {:ok, value} and constant_value(other) == :dynamic
  end

  # Side-effect-free: a variable, a literal, or a call to a whitelisted pure/comparison operator
  # with deterministic arguments.
  defp deterministic?(ast) do
    cond do
      Macro.quoted_literal?(ast) ->
        true

      match?({name, _meta, context} when is_atom(name) and is_atom(context), ast) ->
        true

      match?({op, _meta, args} when is_atom(op) and is_list(args), ast) ->
        {op, _meta, args} = ast
        (op in @const_ops or op in @pure_ops) and Enum.all?(args, &deterministic?/1)

      true ->
        false
    end
  end

  # Structural AST equality, ignoring metadata (line/context annotations).
  defp ast_equal?(a, b), do: strip_meta(a) === strip_meta(b)

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp references_var?(ast, name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _meta, context} = node, _acc when is_atom(context) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp no_quantifier?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {q, _meta, _args} = node, _acc when q in @quantifiers -> {node, true}
        node, acc -> {node, acc}
      end)

    not found?
  end

  # --- Rule: implication precedence -----------------------------------------------------------

  # `~>` is in Elixir's *arrow* operator group, which binds tighter than every comparison. So an
  # unparenthesised comparison consequent gets swallowed:
  #
  #     is_binary(x) ~> String.length(x) <= 10     # (is_binary(x) ~> String.length(x)) <= 10
  #
  # `~>` yields a boolean, and Elixir compares across all types, so the result is a constant whose
  # value depends on the operator: an atom sorts above every number, making `p ~> q >= 0` always
  # true and `p ~> q <= 10` always false. Both are silent — the first asserts nothing, the second
  # rejects every call.
  #
  # No type inference is needed: the rule is the AST shape "an ordering comparison one of whose
  # operands is a `~>` node", which is why this belongs in the compiler lane rather than Credo
  # (#133). Equality operators are excluded — `(p ~> q) == true` is odd but could be deliberate,
  # and the bar here is no false positives.
  #
  # Bond shipped this mistake in its own guide, the `Bond.Predicates` moduledoc and a compile
  # error's suggested fix, which is the argument that it is in user code too.
  defp implication_precedence(expression) do
    expression
    |> collect(&implication_precedence_finding/1)
    |> Enum.reverse()
  end

  defp implication_precedence_finding({op, _, [left, right]} = node)
       when op in @ordering_comparisons do
    cond do
      implication?(left) -> implication_precedence_msg(node, op, left, right)
      implication?(right) -> implication_precedence_msg(node, op, left, right)
      true -> nil
    end
  end

  defp implication_precedence_finding(_node), do: nil

  defp implication?({:~>, _, [_antecedent, _consequent]}), do: true
  defp implication?(_ast), do: false

  defp implication_precedence_msg(node, op, left, right) do
    {implication, other, side} =
      if implication?(left), do: {left, right, :left}, else: {right, left, :right}

    {:~>, meta, [antecedent, consequent]} = implication

    # Rendered by hand: `Macro.to_string/1` of the node reproduces the source verbatim, which is
    # precisely the spelling that misleads. The point is to show where the parentheses land.
    implication_source = Macro.to_string(implication)
    other_source = Macro.to_string(other)

    {parsed_as, intended} =
      case side do
        :left ->
          {"(#{implication_source}) #{op} #{other_source}",
           {:~>, meta, [antecedent, {op, [], [consequent, other]}]}}

        :right ->
          {"#{other_source} #{op} (#{implication_source})",
           {:~>, meta, [antecedent, {op, [], [other, consequent]}]}}
      end

    %{
      rule: :implication_precedence,
      message:
        "Bond assertion linter: `#{Macro.to_string(node)}` compares the result of an " <>
          "implication. `~>` binds tighter than every comparison, so this parses as " <>
          "`#{parsed_as}`" <>
          constant_note(op, left, right) <>
          ". Parenthesise the " <>
          "consequent: `#{Macro.to_string(intended)}`."
    }
  end

  # `~>` returns a boolean, so where the other operand is a literal number or binary the whole
  # comparison folds — `true` and `false` are both atoms and sort the same way against either.
  # Left `:dynamic` when the other operand is anything else, including an atom, where `true` and
  # `false` could compare differently.
  defp constant_note(op, left, right) do
    other = if implication?(left), do: right, else: left

    if is_number(other) or is_binary(other) do
      case {apply(Kernel, op, [true, other]), apply(Kernel, op, [false, other])} do
        {same, same} -> " — always `#{same}`, so it #{constant_phrase(same)}"
        _ -> ""
      end
    else
      ""
    end
  end

  # The clause-fragment form of `constant_effect/1`, which is a whole sentence and does not fit
  # mid-message.
  defp constant_phrase(true), do: "asserts nothing"
  defp constant_phrase(false), do: "fails on every call"

  # Walk `ast`, applying `fun` to every node; accumulate the non-nil results (in reverse order).
  defp collect(ast, fun) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          finding -> {node, [finding | acc]}
        end
      end)

    findings
  end
end
