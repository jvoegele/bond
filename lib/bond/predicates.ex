defmodule Bond.Predicates do
  @moduledoc """
  Predicate functions and operators that are useful in assertions and contract specifications.

  This module is automatically imported for all assertion expressions, specifically in
  preconditions defined with `@pre`, postconditions defined with `@post`, and in uses of
  `Bond.check/1`.

  To use the infix operator versions of the predicates in other contexts, this module must be
  imported in the using module.

  ## Operator precedence

  `~>` (implication) and `<~` (pattern match) share the same precedence and
  left-associate. This matters when both appear in a single assertion. The
  natural-language reading "if `x > 0` then the result matches `{:ok, _}`"

      # WRONG — fails to compile
      @post (x > 0) ~> {:ok, _} <~ result

  parses as `((x > 0) ~> {:ok, _}) <~ result`, where the LHS of `<~` is an
  arbitrary expression containing `_`. `_` isn't a valid value position, so
  compilation fails with a cryptic error.

  Add explicit parens around the inner operator to get the intended grouping:

      # Right
      @post (x > 0) ~> ({:ok, _} <~ result)

  Rule of thumb: any time you nest `<~` inside `~>` (or vice versa),
  parenthesize the inner expression.
  """

  @doc """
  Logical exclusive or: is either `p` or `q` true, but not both?

  For an infix operator version of exclusive or see `|||/2`.

  ## Examples

      iex> xor(true, true)
      false
      iex> xor(true, false)
      true
      iex> xor(false, true)
      true
      iex> xor(false, false)
      false
  """
  @spec xor(as_boolean(term()), as_boolean(term())) :: boolean()
  def xor(p, q), do: (p || q) && !(p && q)

  @doc """
  Logical exclusive or operator: `p ||| q` means `xor(p, q)`.

  Note that the `|||` operator has higher precedence than many other operators and it may be
  necessary to parenthesize the expressions on either side of the operator to get the
  expected result.

  ## Examples

      iex> true ||| true
      false
      iex> true ||| false
      true
      iex> false ||| true
      true
      iex> false ||| false
      false
      iex> x = 2
      2
      iex> y = 4
      4
      iex> (x - y < 0) ||| (y <= x)
      true
  """
  def p ||| q, do: xor(p, q)

  @doc """
  Logical implication: does `p` imply `q`?

  For an infix operator version of logical implication see `~>/2`.

  ## Examples

      iex> implies?(true, true)
      true
      iex> implies?(true, false)
      false
      iex> implies?(false, true)
      true
      iex> implies?(false, false)
      true
  """
  @spec implies?(as_boolean(term()), as_boolean(term())) :: boolean()
  def implies?(p, q), do: !!(!p || q)

  @doc """
  Logical implication operator: `p ~> q` is equivalent to `not p or q`, with
  **short-circuit evaluation** — `q` is only evaluated when `p` is truthy.

  This makes `~>` safe for shape-dependent assertions where the consequent
  would otherwise raise on certain inputs to the antecedent. For example:

      @pre is_binary(x) ~> String.length(x) > 0

  reads "if `x` is a binary, then its length is positive." With the
  short-circuit, `String.length(x)` is never called when `x` isn't a binary
  (which would raise `FunctionClauseError`). This pattern is the canonical
  way to express clause-specific assertions on multi-clause functions where
  contracts must apply uniformly to every clause.

  Note that the `~>` operator has higher precedence than many other operators
  and it may be necessary to parenthesize the expressions on either side of
  the operator to get the expected result. See the
  ["Operator precedence"](#module-operator-precedence) section above.

  ## Examples

      iex> true ~> true
      true
      iex> true ~> false
      false
      iex> false ~> true
      true
      iex> false ~> false
      true
      iex> x = 2
      2
      iex> y = 4
      4
      iex> (x - y < 0) ~> (y > x)
      true
      iex> false ~> raise("not evaluated — antecedent is false")
      true
  """
  defmacro p ~> q do
    # The antecedent goes through `implies?/2` (truthy?) so its narrowed type doesn't reach
    # the `if`; otherwise Dialyzer would flag the `else: true` branch as unreachable when
    # the antecedent is statically `true` (e.g. `is_binary(x) ~> ...` on a binary-typed
    # argument). Lazy evaluation is preserved by emitting the consequent inside the `if`.
    quote do
      if Bond.Predicates.__truthy__(unquote(p)) do
        !!unquote(q)
      else
        true
      end
    end
  end

  @doc false
  # Identity-on-truthiness function used as a Dialyzer-opaque laundering point for `~>`
  # and other places where a guard's narrowed type would make a `false` branch appear
  # unreachable to the type checker. Routes through `:persistent_term.get/2` so Dialyzer
  # genuinely loses the input type at the function boundary (a clause-only `def
  # __truthy__(false) -> false; (_) -> true` still gets narrowed by caller analysis).
  @spec __truthy__(term()) :: boolean()
  def __truthy__(value) do
    case :persistent_term.get(:__bond_opaque_neutralize__, value) do
      false -> false
      nil -> false
      _ -> true
    end
  end

  @doc """
  Pattern matching operator: equivalent to `match?(pattern, expression)`.

  ## Examples

      iex> {:ok, %Date{}} <~ Date.new(1974, 6, 6)
      true
      iex> {:error, _} <~ Date.new(-1, -1, -1)
      true
  """
  defmacro pattern <~ expression do
    # The expression flows through `__opaque__/1` so its static type is widened to
    # `term()` at the `case` discriminator. Without this, a typespec-implied match (e.g.
    # `{:ok, _} <~ result` where `result :: {:ok, integer()}`) lets Dialyzer prove the
    # `_unmatched` clause unreachable, producing `pattern_match_cov` warnings in
    # downstream apps.
    quote do
      case Bond.Predicates.__opaque__(unquote(expression)) do
        unquote(pattern) -> true
        _unmatched -> false
      end
    end
  end

  @doc false
  # Identity function used as a Dialyzer-opaque laundering point. The body routes through
  # `:persistent_term.get/2` whose return type is `term() | Default` — Dialyzer cannot
  # narrow the result. Used by `<~` as a pattern-match discriminator launderer and by
  # Bond's compiler to widen lifted-defp parameter types so user assertions can duplicate
  # typespec-implied guards (`@pre is_binary(x)` on a `@spec` argument of `binary()`)
  # without producing pattern_match warnings in downstream apps.
  @spec __opaque__(term()) :: term()
  def __opaque__(value) do
    :persistent_term.get(:__bond_opaque_neutralize__, value)
  end

  @doc """
  Universal quantifier: asserts that a predicate holds for **every** element of an enumerable.

  Written with comprehension-style generator syntax — `forall(pattern <- enumerable, predicate)`
  — it reads "for all `pattern` in `enumerable`, `predicate`". It is equivalent in truth value
  to `Enum.all?(enumerable, fn pattern -> predicate end)`, but on failure Bond reports **which
  element violated the predicate** and its zero-based index, rather than only that the whole
  expression was false:

      precondition all_positive failed for call to M.scale/1
      |   assertion: forall(x <- items, x > 0)
      |   counterexample: element at index 3 (-2) does not satisfy `x > 0`

  Evaluation **short-circuits** at the first violating element. An empty enumerable is vacuously
  `true`. A predicate that raises (rather than returning falsy) propagates — guard
  shape-dependent predicates with `~>`, exactly as in multi-clause contracts.

  `forall`/`exists` return ordinary booleans, so they compose with `and`, `or`, `not`, `~>`,
  and `|||`. When several quantifiers appear in one assertion (including nested ones), the
  element-level detail reflects the *last* quantifier to fail; for a bare quantifier it is
  exact.

  ## Examples

      iex> import Bond.Predicates
      iex> forall(x <- [1, 2, 3], x > 0)
      true
      iex> forall(x <- [1, -2, 3], x > 0)
      false
      iex> forall(x <- [], x > 0)
      true
  """
  defmacro forall({:<-, _, [pattern, enum]}, predicate) do
    quote do
      Bond.Runtime.Quantifier.forall(
        unquote(enum),
        fn unquote(pattern) -> unquote(predicate) end,
        unquote(Macro.to_string(predicate))
      )
    end
  end

  defmacro forall(generator, _predicate) do
    raise ArgumentError,
          "forall/2 expects a generator `pattern <- enumerable` as its first argument, " <>
            "got: #{Macro.to_string(generator)}"
  end

  @doc """
  Existential quantifier: asserts that a predicate holds for **at least one** element of an
  enumerable.

  Written `exists(pattern <- enumerable, predicate)` — "there exists a `pattern` in
  `enumerable` such that `predicate`". Equivalent in truth value to
  `Enum.any?(enumerable, fn pattern -> predicate end)`. Evaluation **short-circuits** at the
  first satisfying element.

  Unlike `forall/2`, a failure has no single offending element, so the diagnostic reports that
  no element satisfied the predicate, along with the number of elements checked:

      precondition has_admin failed for call to M.authorize/1
      |   assertion: exists(u <- users, u.role == :admin)
      |   counterexample: no element of `users` satisfies `u.role == :admin` (3 elements)

  An empty enumerable is `false` (no witness exists).

  ## Examples

      iex> import Bond.Predicates
      iex> exists(x <- [1, 2, 3], x > 2)
      true
      iex> exists(x <- [1, 2, 3], x > 5)
      false
      iex> exists(x <- [], x > 0)
      false
  """
  defmacro exists({:<-, _, [pattern, enum]}, predicate) do
    quote do
      Bond.Runtime.Quantifier.exists(
        unquote(enum),
        fn unquote(pattern) -> unquote(predicate) end,
        unquote(Macro.to_string(predicate)),
        unquote(Macro.to_string(enum))
      )
    end
  end

  defmacro exists(generator, _predicate) do
    raise ArgumentError,
          "exists/2 expects a generator `pattern <- enumerable` as its first argument, " <>
            "got: #{Macro.to_string(generator)}"
  end
end
