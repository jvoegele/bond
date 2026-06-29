defmodule Bond.Compiler.Boundaries do
  @moduledoc internal: true
  @moduledoc """
  Compile-time extraction of *boundary candidate values* from precondition assertion
  expressions, for contract-driven property testing (#36).

  Given a function's precondition expressions and its positional parameter names, `extract/2`
  finds two kinds of boundary and maps the argument's *positional index* to a list of *probes*:

    * **Value boundaries** — `arg <op> literal` (`>=`, `>`, `<=`, `<`, `==`, `!=`, and
      `arg in low..high`) contribute the bare numbers straddling the boundary: the literal `n`
      itself plus its neighbours `n - 1` and `n + 1`.
    * **Size boundaries** — `wrapper(arg) <op> literal`, where `wrapper` is one of `length`,
      `byte_size`, `tuple_size`, or `map_size`, contribute `{:size, wrapper, n}` tuples for the
      target sizes straddling the boundary (clamped to `n >= 0` — a collection can't have negative
      size). `Bond.PropertyTest` constructs collections/binaries of those sizes from the
      user-supplied generator's output.

  An argument's probe list therefore mixes plain numbers (value probes) and `{:size, …}` tuples
  (size probes); in practice an argument is one or the other, since a value can't be both a number
  and a sized collection. `Bond.PropertyTest` mixes these probes into the user-supplied generator
  for that argument so the property is probed exactly at its precondition edges, where off-by-one
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
      its base generator and filtered by `@pre`. (#43)
    * **Stepped ranges** — `arg in low..high//step`: only the plain two-element `low..high` form is
      recognised.
    * **Wrappers over a derived expression** — `length(tl(items)) <= 3`, `byte_size(a <> b) > 0`:
      only a wrapper applied *directly* to a bare argument is recognised as a size boundary.

  These omissions are safe: a skipped comparison costs only the boundary *probe*, never
  correctness — the precondition is still enforced as the test oracle at every call.
  """

  # Comparison operators whose literal operand defines a boundary. `==`/`!=` are included
  # uniformly: for `x == 5` the neighbours `4` and `6` are filtered out and only `5` survives;
  # for `x != 5` the reverse. The `@pre` filter makes the per-operator semantics fall out for free.
  @comparison_ops [:>=, :>, :<=, :<, :==, :!=]

  # Kernel size/length introspection functions whose argument's *size* a literal comparison bounds
  # (#43). Each maps to a collection type `Bond.PropertyTest` knows how to resize: `length` → list,
  # `byte_size` → binary, `tuple_size` → tuple, `map_size` → map.
  @size_wrappers [:length, :byte_size, :tuple_size, :map_size]

  @doc """
  Extracts boundary probes from a list of precondition `expression` ASTs.

  `arg_names` is the function's parameter names in positional order — e.g. `[:account, :amount]`
  for `def withdraw(account, amount)`. Returns a map of `arg_index => sorted, unique list of
  probes`, where a probe is either a bare number (a *value* boundary) or a `{:size, wrapper, n}`
  tuple (a *size* boundary — construct a collection of size `n`). Arguments that no precondition
  constrains against a literal are absent from the map (the caller leaves their generator
  untouched).

      iex> alias Bond.Compiler.Boundaries
      iex> Boundaries.extract([quote(do: amount >= 0)], [:account, :amount])
      %{1 => [-1, 0, 1]}

      iex> alias Bond.Compiler.Boundaries
      iex> Boundaries.extract([quote(do: length(items) <= 3)], [:items])
      %{0 => [{:size, :length, 2}, {:size, :length, 3}, {:size, :length, 4}]}
  """
  @type probe :: number() | {:size, atom(), non_neg_integer()}
  @spec extract([Macro.t()], [atom()]) :: %{optional(non_neg_integer()) => [probe()]}
  def extract(expressions, arg_names) when is_list(expressions) and is_list(arg_names) do
    index_by_name = arg_names |> Enum.with_index() |> Map.new()

    expressions
    |> Enum.flat_map(&boundary_pairs(&1, index_by_name))
    |> Enum.group_by(fn {index, _probe} -> index end, fn {_index, probe} -> probe end)
    |> Map.new(fn {index, probes} -> {index, probes |> Enum.uniq() |> Enum.sort()} end)
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

  # `arg <op> literal` (value boundary) or `wrapper(arg) <op> literal` (size boundary), in either
  # operand order. A bare argument yields straddling value probes; a size wrapper yields
  # `{:size, wrapper, n}` probes for the target sizes.
  defp boundary_at_node({op, _meta, [lhs, rhs]}, index_by_name) when op in @comparison_ops do
    cond do
      pair = arg_literal(lhs, rhs, index_by_name) ->
        {index, value} = pair
        Enum.map(candidates(value), &{index, &1})

      spec = wrapper_literal(lhs, rhs, index_by_name) ->
        {index, wrapper, value} = spec
        Enum.map(size_candidates(value), &{index, {:size, wrapper, &1}})

      true ->
        []
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

  # Finds the `{arg_index, wrapper, literal}` triple of a comparison where one side is a size
  # wrapper applied to a bare argument (`length(items) <= 3`) and the other is a numeric literal,
  # trying each operand order. Returns `nil` when no side is such a wrapper-over-argument call.
  defp wrapper_literal(lhs, rhs, index_by_name) do
    wrapper_triple(wrapper_arg(lhs, index_by_name), literal_value(rhs)) ||
      wrapper_triple(wrapper_arg(rhs, index_by_name), literal_value(lhs))
  end

  defp wrapper_triple(nil, _value), do: nil
  defp wrapper_triple(_wrapper_arg, nil), do: nil
  defp wrapper_triple({index, wrapper}, value), do: {index, wrapper, value}

  # A size wrapper applied directly to a bare argument — `length(items)`, `byte_size(s)`, etc. The
  # argument node must itself be a bare parameter (same shape rule as `arg_index/2`); a wrapper over
  # a derived expression like `length(tl(items))` is not recognised. Returns `{arg_index, wrapper}`
  # or `nil`.
  defp wrapper_arg({wrapper, _meta, [arg]}, index_by_name) when wrapper in @size_wrappers do
    case arg_index(arg, index_by_name) do
      nil -> nil
      index -> {index, wrapper}
    end
  end

  defp wrapper_arg(_other, _index_by_name), do: nil

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

  # Target sizes for a size boundary `n`: `n - 1`, `n`, `n + 1`, clamped to non-negative — a
  # collection can't have negative size, so `byte_size(s) > 0` (boundary `0`) probes sizes `0` and
  # `1` only. A non-integer size literal (`length(x) <= 1.5`, nonsensical) yields no probes.
  defp size_candidates(value) when is_integer(value) do
    [value - 1, value, value + 1] |> Enum.filter(&(&1 >= 0))
  end

  defp size_candidates(_value), do: []
end
