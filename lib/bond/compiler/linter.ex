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

  Every rule is *structural* (no type inference) and fires only on provably-constant shapes —
  when in doubt, it stays silent, because a noisy contract linter gets disabled wholesale.

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
  """

  @typedoc """
  A single lint finding: `:rule` identifies which rule fired; `:message` is the human-readable
  diagnostic (already including the offending code).
  """
  @type finding :: %{
          rule: :constant_assertion | :self_comparison | :vacuous_quantifier,
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

  @doc """
  Analyses an assertion `expression` and returns a (possibly empty) list of `t:finding/0`.

  Pure — performs no I/O. `warn/2` is the side-effecting counterpart used by the compiler.
  """
  @spec check(Macro.t()) :: [finding()]
  def check(expression) do
    Enum.concat([
      constant_assertion(expression),
      self_comparisons(expression),
      vacuous_quantifiers(expression)
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
                "`#{inspect(value)}` — it can never fail and so asserts nothing. Compare values " <>
                "that could actually differ, or remove the assertion."
          }
        ]

      :dynamic ->
        []
    end
  end

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
      negation_pair?(a, b) -> tautology_msg(node, true)
      true -> nil
    end
  end

  # `false and _` / `_ and false`, or `p and not p`.
  defp self_comparison_finding({:and, _, [a, b]} = node) do
    cond do
      dominant?(a, b, false) or dominant?(b, a, false) -> dominance_msg(node, false)
      negation_pair?(a, b) -> tautology_msg(node, false)
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
          "forces the result regardless of the other, so it asserts nothing."
    }
  end

  defp tautology_msg(node, value) do
    %{
      rule: :self_comparison,
      message:
        "Bond assertion linter: `#{Macro.to_string(node)}` is always `#{value}` (a term " <>
          "combined with its own negation) — it asserts nothing."
    }
  end

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
