defmodule Bond.Compiler.Boundaries do
  @moduledoc internal: true
  @moduledoc """
  Compile-time extraction of *boundary candidate values* from precondition assertion
  expressions, for contract-driven property testing (#36).

  Given a function's precondition expressions and its positional parameter names, `extract/2`
  finds every comparison of the form `arg <op> literal` (`>=`, `>`, `<=`, `<`, `==`, `!=`, and
  `arg in low..high`) and maps the argument's *positional index* to a small set of candidate
  values straddling the boundary — the literal `n` itself plus its neighbours `n - 1` and
  `n + 1`. `Bond.PropertyTest` later mixes these candidates into the user-supplied generator for
  that argument so the property is probed exactly at its precondition edges, where off-by-one
  postcondition bugs live.

  ## Why straddle the boundary instead of computing the valid side

  Extraction is deliberately *generous and type-agnostic*. It does not try to decide whether an
  operator is strict (`>` vs `>=`) or whether the argument is an integer or a float — from the AST
  alone it cannot know the latter. Instead it emits `n - 1`, `n`, `n + 1` for every boundary and
  relies on the runtime `@pre` filter (`__bond_precondition__/3`) to discard any candidate that
  does not actually satisfy the precondition. So for `@pre x > 0` the candidate `0` is generated
  and then filtered out, while `1` survives — no strictness analysis needed here.

  ## What is intentionally skipped (filter-only, no injected candidates)

    * **Relational comparisons** — `amount <= account.balance`: neither side is an `arg <op>
      literal`, so there is no literal boundary to inject. The argument is still exercised through
      its base generator and filtered by `@pre`.
    * **Size/length wrappers** — `length(items) <= 10`, `byte_size(s) > 0`: the boundary is on a
      derived quantity, not on the argument's own value, so no value can be injected directly.
      (Constructing collections of a target size is a possible future refinement.)
    * **Stepped ranges** — `arg in low..high//step`: only the plain two-element `low..high` form is
      recognised.

  These omissions are safe: a skipped comparison costs only the boundary *probe*, never
  correctness — the precondition is still enforced as the test oracle at every call.
  """

  # Comparison operators whose literal operand defines a boundary. `==`/`!=` are included
  # uniformly: for `x == 5` the neighbours `4` and `6` are filtered out and only `5` survives;
  # for `x != 5` the reverse. The `@pre` filter makes the per-operator semantics fall out for free.
  @comparison_ops [:>=, :>, :<=, :<, :==, :!=]

  @doc """
  Extracts boundary candidate values from a list of precondition `expression` ASTs.

  `arg_names` is the function's parameter names in positional order — e.g. `[:account, :amount]`
  for `def withdraw(account, amount)`. Returns a map of `arg_index => sorted, unique list of
  candidate values`. Arguments that no precondition constrains against a literal are absent from
  the map (the caller leaves their generator untouched).

      iex> alias Bond.Compiler.Boundaries
      iex> Boundaries.extract([quote(do: amount >= 0)], [:account, :amount])
      %{1 => [-1, 0, 1]}
  """
  @spec extract([Macro.t()], [atom()]) :: %{optional(non_neg_integer()) => [number()]}
  def extract(expressions, arg_names) when is_list(expressions) and is_list(arg_names) do
    index_by_name = arg_names |> Enum.with_index() |> Map.new()

    expressions
    |> Enum.flat_map(&boundary_pairs(&1, index_by_name))
    |> Enum.group_by(fn {index, _value} -> index end, fn {_index, value} -> value end)
    |> Map.new(fn {index, values} -> {index, values |> Enum.uniq() |> Enum.sort()} end)
  end

  # Walks one expression collecting every `{arg_index, candidate_value}` pair. `Macro.prewalk`
  # visits each node; `boundary_at_node/2` returns the pairs contributed by that node (or `[]`),
  # so nested comparisons inside `and`/`or`/`~>` are all captured.
  defp boundary_pairs(expression, index_by_name) do
    {_ast, pairs} =
      Macro.prewalk(expression, [], fn node, acc ->
        {node, boundary_at_node(node, index_by_name) ++ acc}
      end)

    pairs
  end

  # `arg in low..high` — inject candidates straddling both bounds.
  defp boundary_at_node({:in, _meta, [operand, {:.., _range_meta, [low, high]}]}, index_by_name) do
    case arg_index(operand, index_by_name) do
      nil -> []
      index -> for bound <- [low, high], value <- literal_candidates(bound), do: {index, value}
    end
  end

  # `arg <op> literal` (in either operand order).
  defp boundary_at_node({op, _meta, [lhs, rhs]}, index_by_name) when op in @comparison_ops do
    case arg_literal(lhs, rhs, index_by_name) do
      nil -> []
      {index, value} -> Enum.map(candidates(value), &{index, &1})
    end
  end

  defp boundary_at_node(_node, _index_by_name), do: []

  # Finds the `{arg_index, literal}` pairing of a binary comparison, trying the argument on the
  # left then on the right. Returns `nil` when no side is a bare argument compared to a numeric
  # literal (e.g. relational `amount <= account.balance`, or constant-folded `5 >= 3`).
  defp arg_literal(lhs, rhs, index_by_name) do
    pair(arg_index(lhs, index_by_name), literal_value(rhs)) ||
      pair(arg_index(rhs, index_by_name), literal_value(lhs))
  end

  defp pair(nil, _value), do: nil
  defp pair(_index, nil), do: nil
  defp pair(index, value), do: {index, value}

  # A bare argument reference is a variable node `{name, meta, context}` whose name is one of the
  # function's parameters and whose context is an atom (distinguishing it from a call like
  # `length(x)`, whose third element is an argument list). Returns the positional index or `nil`.
  defp arg_index({name, _meta, context}, index_by_name)
       when is_atom(name) and is_atom(context) do
    Map.get(index_by_name, name)
  end

  defp arg_index(_other, _index_by_name), do: nil

  # Recognises numeric literals, including a unary-minus on a literal (`-5`, `-0.5`). Anything
  # else (variables, calls, field access, strings) is not a boundary literal.
  defp literal_value(value) when is_number(value), do: value
  defp literal_value({:-, _meta, [value]}) when is_number(value), do: -value
  defp literal_value(_other), do: nil

  defp literal_candidates(bound) do
    case literal_value(bound) do
      nil -> []
      value -> candidates(value)
    end
  end

  # The boundary `n` plus its immediate neighbours, typed to match the literal so integer
  # boundaries stay integers and float boundaries stay floats. Finer float-epsilon probing is a
  # possible future refinement.
  defp candidates(value) when is_integer(value), do: [value - 1, value, value + 1]
  defp candidates(value) when is_float(value), do: [value - 1.0, value, value + 1.0]
end
