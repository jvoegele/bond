defmodule Bond.Compiler.Clauses do
  @moduledoc internal: true
  @moduledoc """
  Clause-shape utilities for multi-clause function wrapper generation.

  Bond's contract semantics are *uniform across clauses*: a single set of `@pre` /
  `@post` / `@invariant` applies to every clause of a multi-clause function. To
  make that work with per-clause wrapper emission (0.17.0), Bond needs a single
  canonical name per positional argument that's stable across clauses. This
  module owns that extraction and the rule that all clauses must agree on those
  names.

  ## "Top-level name"

  For each clause parameter, the *top-level name* is the variable bound to that
  positional argument at the outer level of the pattern:

    * `def f(x)` — top-level name `x`.
    * `def f(%Mod{f: y} = z)` — top-level name `z`.
    * `def f(z = %Mod{f: y})` — top-level name `z` (reversed match).
    * `def f(x) when is_struct(x, Mod)` — top-level name `x` (the guard mentions
      it but the binding comes from the bare-variable param).
    * `def f(%Mod{f: y})` (no `=`), `def f(0)`, `def f(_)`, `def f([h | t])` —
      no top-level name. Bond will pick a canonical name from a sibling clause
      if one exists, or generate `__bond_arg_<idx>__` otherwise.

  ## Agreement rule (the 0.17.0 break)

  At each positional argument, all clauses that *bind* a top-level name must
  agree on what that name is. A clause with no top-level name (literal pattern,
  wildcard, destructure-only) doesn't constrain the canonical — it adopts
  whatever sibling clauses name. If no clause names a position, Bond uses
  `__bond_arg_<idx>__`; contracts can't reference that position by name.

  Disagreement raises a `CompileError` with the canonical fix (rename all
  clauses to use one consistent name per position).
  """

  @typedoc """
  Result of `top_level_names/1` for a single clause: a list with one entry per
  positional argument. An entry is an atom (the bound name) or `nil` (no
  top-level name).
  """
  @type clause_names :: [atom() | nil]

  @doc """
  Returns the top-level name list for a single clause's params.

  See the moduledoc for what "top-level name" means at each position.
  """
  @spec top_level_names([Macro.t()]) :: clause_names()
  def top_level_names(params) when is_list(params) do
    Enum.map(params, &top_level_name/1)
  end

  @doc """
  Computes the canonical name list for an `AnnotatedFunction`'s clauses,
  aggregating across all of them. Returns:

    * `{:ok, canonical}` — a list of atom names, one per positional argument.
      Each name is the unique top-level name agreed across all naming clauses
      at that position, or a generated `:"__bond_arg_<idx>__"` if no clause
      named it.
    * `{:error, {:disagreement, position_index, names}}` — at least one
      position has two or more distinct top-level names across clauses.
      `names` is the deduplicated list of the conflicting names in clause-
      encounter order, for the diagnostic.
  """
  @spec canonical_names(nonempty_list(clause_names())) ::
          {:ok, [atom()]}
          | {:error, {:disagreement, non_neg_integer(), [atom()]}}
  def canonical_names([first | _] = clauses_names) when is_list(first) do
    arity = length(first)

    Enum.reduce_while(0..(arity - 1)//1, {:ok, []}, fn idx, {:ok, acc} ->
      proposed_names =
        clauses_names
        |> Enum.map(&Enum.at(&1, idx))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case proposed_names do
        [] -> {:cont, {:ok, [generated_name(idx) | acc]}}
        [name] -> {:cont, {:ok, [name | acc]}}
        more -> {:halt, {:error, {:disagreement, idx, more}}}
      end
    end)
    |> case do
      {:ok, names_reversed} -> {:ok, Enum.reverse(names_reversed)}
      err -> err
    end
  end

  def canonical_names([]), do: {:ok, []}

  @doc """
  Returns the generated canonical name for a 0-based positional argument that
  no clause bound. Used by `canonical_names/1` and by the wrapper rewrite when
  the canonical at a position is generated.
  """
  @spec generated_name(non_neg_integer()) :: atom()
  def generated_name(idx) when is_integer(idx) and idx >= 0 do
    :"__bond_arg_#{idx}__"
  end

  @doc """
  Underscore-prefixes every bound variable in `pattern` whose name isn't in the
  `used` set. Names already starting with underscore (`_foo`) and bare wildcards
  (`_`) are left alone. Pin expressions (`^x`) are treated as uses, not bindings,
  and are not rewritten.

  This is the #3 fix from the Photon dogfood: when Bond's wrapper duplicates the
  user's destructure pattern in its head but the wrapper body only references the
  top-level binding, Elixir emits "unused variable" warnings for every
  destructured name. Underscore-prefixing those names suppresses the warning
  while keeping the pattern's match shape identical.

  The `used` set should contain every name that:

    * The wrapper body references (typically the canonical top-level names that
      get passed to `super/N` and the lifted assertion defps).
    * Any contract expression references (so contract-author-facing bindings
      aren't underscored out).
  """
  @spec underscore_prefix_unused(Macro.t(), MapSet.t(atom()) | Enumerable.t()) :: Macro.t()
  def underscore_prefix_unused(pattern, used) do
    used_set = if is_struct(used, MapSet), do: used, else: MapSet.new(used)
    do_prefix(pattern, used_set)
  end

  # Pin: the inner variable is a USE, not a binding. Don't rewrite.
  defp do_prefix({:^, meta, [inner]}, _used) do
    {:^, meta, [inner]}
  end

  # Match: both sides are patterns. Recurse on both.
  defp do_prefix({:=, meta, [lhs, rhs]}, used) do
    {:=, meta, [do_prefix(lhs, used), do_prefix(rhs, used)]}
  end

  # Variable binding.
  defp do_prefix({name, meta, ctx} = node, used) when is_atom(name) and is_atom(ctx) do
    cond do
      name == :_ -> node
      MapSet.member?(used, name) -> node
      String.starts_with?(Atom.to_string(name), "_") -> node
      true -> {:"_#{name}", meta, ctx}
    end
  end

  # Other 3-tuple AST node (function call, struct pattern, etc.). Recurse into
  # head and args. Head is typically an atom (call name) but may be itself a
  # 3-tuple for remote calls — recursing handles both.
  defp do_prefix({head, meta, args}, used) when is_list(args) do
    {do_prefix(head, used), meta, Enum.map(args, &do_prefix(&1, used))}
  end

  # 2-tuple (keyword pair, two-element tuple literal). Recurse on both elements.
  defp do_prefix({a, b}, used) do
    {do_prefix(a, used), do_prefix(b, used)}
  end

  # List (cons-list literals, args lists). Recurse on each element.
  defp do_prefix(list, used) when is_list(list) do
    Enum.map(list, &do_prefix(&1, used))
  end

  # Literal (atom, integer, binary, etc.). Pass through.
  defp do_prefix(literal, _used), do: literal

  # --- Pattern recognition for one parameter ---

  # `{name, _meta, ctx}` where ctx is an atom — bare variable.
  defp top_level_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    cond do
      # Wildcards (`_` alone) have name :_; treat as no top-level name. Bond
      # will rewrite the wrapper pattern to bind a generated/canonical name.
      name == :_ -> nil
      true -> name
    end
  end

  # `pattern = name` — match with name on the right.
  defp top_level_name({:=, _, [_pattern, {name, _, ctx}]})
       when is_atom(name) and is_atom(ctx) and name != :_ do
    name
  end

  # `name = pattern` — match with name on the left.
  defp top_level_name({:=, _, [{name, _, ctx}, _pattern]})
       when is_atom(name) and is_atom(ctx) and name != :_ do
    name
  end

  # Anything else (literal patterns, destructure-only, wildcards, complex
  # nested patterns) has no top-level name.
  defp top_level_name(_), do: nil
end
