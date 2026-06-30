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
  @spec canonical_names(
          nonempty_list(clause_names()),
          MapSet.t(atom()) | :all
        ) ::
          {:ok, [atom()]}
          | {:error, {:disagreement, non_neg_integer(), [atom()]}}
  def canonical_names(clauses_names, required_names \\ :all)

  def canonical_names([], _required_names), do: {:ok, []}

  def canonical_names([first | _] = clauses_names, required_names) when is_list(first) do
    arity = length(first)

    Enum.reduce_while(0..(arity - 1)//1, {:ok, []}, fn idx, {:ok, acc} ->
      raw_proposed =
        clauses_names
        |> Enum.map(&Enum.at(&1, idx))
        |> Enum.reject(&is_nil/1)

      # Normalize for agreement: `_a` and `a` represent the same binding
      # semantically (Elixir's leading-underscore convention is "bound but
      # intentionally unused"). The canonical at this position is the
      # non-underscored form. Wildcards (bare `_`) are already filtered out
      # above as nil and aren't part of this set.
      normalized = raw_proposed |> Enum.map(&normalize_name/1) |> Enum.uniq()

      case normalized do
        [] ->
          {:cont, {:ok, [generated_name(idx) | acc]}}

        [name] ->
          {:cont, {:ok, [name | acc]}}

        _multiple ->
          # Multiple distinct (normalized) names at this position. The
          # disagreement is a CompileError only if some assertion references
          # a name at this position (or `required_names` is `:all`).
          # Otherwise generate a name and move on.
          if position_required?(raw_proposed, required_names) do
            {:halt, {:error, {:disagreement, idx, Enum.uniq(raw_proposed)}}}
          else
            {:cont, {:ok, [generated_name(idx) | acc]}}
          end
      end
    end)
    |> case do
      {:ok, names_reversed} -> {:ok, Enum.reverse(names_reversed)}
      err -> err
    end
  end

  # Strip a single leading underscore from a name. `_a` → `a`, `a` → `a`.
  # Bare `_` and shorter forms pass through untouched (never produced as a
  # top-level name anyway — `top_level_name/1` returns nil for those).
  defp normalize_name(name) when is_atom(name) do
    case Atom.to_string(name) do
      "_" <> rest when rest != "" -> String.to_atom(rest)
      _ -> name
    end
  end

  defp position_required?(_proposed_names, :all), do: true

  defp position_required?(proposed_names, %MapSet{} = required_names) do
    Enum.any?(proposed_names, fn name ->
      MapSet.member?(required_names, name) or
        MapSet.member?(required_names, normalize_name(name))
    end)
  end

  @doc """
  Returns the generated canonical name for a 0-based positional argument that
  no clause bound. Used by `canonical_names/1` and by the wrapper rewrite when
  the canonical at a position is generated.
  """
  @spec generated_name(non_neg_integer()) :: atom()
  def generated_name(idx) when is_integer(idx) and idx >= 0 do
    # No leading underscore: Elixir warns "underscored variable used after
    # being set" when an underscore-prefixed name appears in an expression
    # position (e.g. as a super_args / lifted-defp-call arg). The wrapper
    # body DOES use the canonical name, so the prefix is incompatible.
    :"bond_arg_#{idx}"
  end

  @doc """
  Validates that every clause in `clauses` agrees on the top-level name at each
  positional argument. Returns `{:ok, canonical_names}` on success, or raises
  `CompileError` at `env`'s file/line with a clear diagnostic on disagreement.

  This is the 0.17.0 break: multi-clause functions with `@pre` / `@post` /
  `@invariant`-emitted overrides must use consistent top-level parameter names
  across all clauses. The diagnostic names the disagreeing position, lists the
  conflicting names, and points at the canonical fix (rename to one consistent
  name per position) plus the deferred per-clause-contracts door.

  `clauses` is a list of structs (or maps) with a `:params` field; the order
  matters only for the error message. `function_info` is `{name, arity}`, used
  to name the function in the diagnostic.
  """
  @spec assert_clauses_agree!(
          [%{:params => [Macro.t()], optional(any()) => any()}],
          Macro.Env.t(),
          {atom(), non_neg_integer()},
          MapSet.t(atom()) | :all
        ) :: {:ok, [atom()]}
  def assert_clauses_agree!(
        clauses,
        %Macro.Env{} = env,
        {fun, arity} = _function_info,
        required_names \\ :all
      )
      when is_list(clauses) do
    clauses_names = Enum.map(clauses, &top_level_names(&1.params || []))

    case canonical_names(clauses_names, required_names) do
      {:ok, names} ->
        {:ok, names}

      {:error, {:disagreement, idx, conflicting}} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: disagreement_message(fun, arity, idx, conflicting, clauses_names)
    end
  end

  @doc """
  Returns the subset of parameter names that any of the given `assertions`
  reference. The result is intersected with the union of top-level names
  across `clauses`, so synthetic bindings like `result`, `old(...)` helpers,
  and the invariant `subject` (none of which appear as a top-level name on
  any clause) are filtered out automatically.

  This is the input to `assert_clauses_agree!/4`'s relaxed mode: clauses
  only need to agree on a positional name when some assertion actually
  references that name.

  ## False positives

  A closure variable inside a contract expression (`Enum.all?(xs, fn x -> ...
  end)`) that happens to share a name with a parameter IS collected — the
  AST walk can't distinguish closure scope from outer scope. The result is
  over-strict in this edge case (agreement is required at the parameter's
  position even though the contract doesn't actually depend on it). The
  workaround is to rename either the closure var or the parameter. Agreement
  is over-required, never under-required.
  """
  @spec referenced_param_names(
          [%{:expression => Macro.t(), optional(any()) => any()}],
          [%{:params => [Macro.t()], optional(any()) => any()}]
        ) :: MapSet.t(atom())
  def referenced_param_names(assertions, clauses)
      when is_list(assertions) and is_list(clauses) do
    candidates =
      clauses
      |> Enum.flat_map(&top_level_names(&1.params || []))
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&candidate_variants/1)
      |> MapSet.new()

    referenced =
      Enum.reduce(assertions, MapSet.new(), fn assertion, acc ->
        MapSet.union(acc, assertion_referenced_names(assertion))
      end)

    MapSet.intersection(referenced, candidates)
  end

  # The parameter names an assertion references. For an ordinary assertion that's just the free
  # names of its expression. For an assertion scoped to a `where`/`whenever` binding group (#47),
  # the expression is evaluated *inside* the `case` clause that binds the pattern's names, so:
  #
  #   * names bound by the binding pattern are NOT parameter references — they shadow any
  #     same-named parameter (which is why keeping the parameter would otherwise produce an
  #     "unused variable" warning), so subtract them; and
  #   * the binding source IS evaluated in the parameter scope, so its free names ARE references
  #     (e.g. `whenever({:ok, x} <- acc)` must keep `acc`, or a multi-clause lifted defp would
  #     drop it).
  defp assertion_referenced_names(%{
         binding: %{pattern: pattern, source: source},
         expression: expr
       }) do
    member_refs = MapSet.difference(collect_var_names(expr), pattern_binding_names(pattern))
    MapSet.union(member_refs, collect_var_names(source))
  end

  defp assertion_referenced_names(%{expression: expr}), do: collect_var_names(expr)

  # For every clause's top-level name, include both `_name` and `name` in the
  # candidate set so contracts referencing either spelling are recognised
  # symmetrically. Mirrors the `_a`/`a` equivalence the agreement check
  # applies — Elixir's leading-underscore convention is "bound but
  # intentionally unused", so the two forms are semantically the same
  # parameter.
  defp candidate_variants(name) when is_atom(name) do
    case Atom.to_string(name) do
      "_" <> rest when rest != "" ->
        [name, String.to_atom(rest)]

      str ->
        [name, String.to_atom("_" <> str)]
    end
  end

  @doc """
  Returns the set of bare-variable names referenced anywhere in `guards` — a
  clause's list of guard expression ASTs (as stored on
  `Bond.Compiler.AnnotatedFunction.Clause`; `[]` means no guard).

  `Bond.Compiler.ClauseWrapper` passes this as the `used` set to
  `rewrite_clause_params/3` so guard-referenced names are kept out of the
  underscore-prefixing pass: a wrapper head that underscored `key` while its
  `when is_binary(key)` guard still referenced `key` would fail to compile (or
  warn about an underscored variable used in a guard).
  """
  @spec guard_var_names([Macro.t()]) :: MapSet.t(atom())
  def guard_var_names(guards) when is_list(guards) do
    Enum.reduce(guards, MapSet.new(), fn guard, acc ->
      MapSet.union(acc, collect_var_names(guard))
    end)
  end

  @doc """
  Returns the set of *free* bare-variable names referenced in `ast` — the variables that must
  resolve to something outside the expression (a function argument, or `result` in a `@post`).

  A bare variable is `{name, meta, ctx}` with `name` and `ctx` both atoms; local and remote
  calls (whose third element is an argument list, e.g. `is_integer(x)` or `old(amount)`) are
  *not* themselves variables, though any bare variables nested in their arguments are collected.

  Names bound *within* the expression are excluded. The only binding form a Bond contract
  expression introduces is the `<~` match operator (`Bond.Predicates.<~/2`), whose left-hand
  pattern binds names locally — it expands to a `case` clause head. So in
  `({:ok, path} when is_binary(path)) <~ result` the only free name is `result`; `path` is
  bound by the pattern. A `when` guard on that pattern may still reference an outer name
  (`({:ok, v} when v > limit) <~ result`), so guard references are *not* excluded — only the
  pattern's own bindings are.

  Used by `Bond.Protocol` and `Bond.Behaviour` to check that a contract references only names
  the function actually binds (its arguments, plus `result` in a postcondition).
  """
  @spec expression_var_names(Macro.t()) :: MapSet.t(atom())
  def expression_var_names(ast) do
    MapSet.difference(collect_var_names(ast), match_pattern_bound_names(ast))
  end

  # Collects the names bound by the left-hand pattern of every `<~` match operator in `ast`
  # (at any depth — e.g. nested inside a `~>` implication). For each `pattern <~ _expr`, only
  # the pattern's variables are bound; if the pattern carries a `when` guard, the guard's
  # references are excluded from the binding set so a guard reference to an outer name still
  # surfaces as free in `expression_var_names/1`.
  defp match_pattern_bound_names(ast) do
    {_, patterns} =
      Macro.prewalk(ast, [], fn
        {:<~, _, [lhs, _rhs]} = node, acc -> {node, [pattern_of(lhs) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reduce(patterns, MapSet.new(), fn pattern, acc ->
      MapSet.union(acc, pattern_binding_names(pattern))
    end)
  end

  # The binding side of a `<~` LHS: the pattern before any `when` guard, or the whole LHS when
  # there is no guard.
  defp pattern_of({:when, _, [pattern, _guard]}), do: pattern
  defp pattern_of(pattern), do: pattern

  # Variable names a pattern binds. Every bare variable in a pattern is a binding *except* a
  # pinned `^var`, which is a reference to an outer value — neutralise pinned subtrees (replace
  # them with a non-variable node) before collecting so the pinned name stays free.
  defp pattern_binding_names(pattern) do
    pattern
    |> Macro.prewalk(fn
      {:^, _, [_pinned]} -> {:__bond_pinned__, [], []}
      other -> other
    end)
    |> collect_var_names()
  end

  # Walks an AST collecting every bare-variable reference. A bare variable in
  # Elixir AST is `{name, _meta, ctx}` where both `name` and `ctx` are atoms
  # (call AST has a list args at elem 2 instead of an atom context, so it's
  # not picked up here). Remote-call heads (`{:., _, [_, _]}`) aren't atoms
  # either and are skipped.
  defp collect_var_names(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {name, _meta, ctx} = node, acc
        when is_atom(name) and is_atom(ctx) and name != :_ ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(names)
  end

  defp disagreement_message(fun, arity, idx, conflicting, clauses_names) do
    conflicting_str = conflicting |> Enum.map(&inspect/1) |> Enum.join(", ")

    clause_summary =
      clauses_names
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {names, clause_num} ->
        "  clause #{clause_num}: " <>
          (names |> Enum.map(&format_name/1) |> Enum.join(", "))
      end)

    """
    Bond requires consistent top-level parameter names across all clauses of #{fun}/#{arity} \
    when contracts are attached. Position #{idx} disagrees: #{conflicting_str}.

    Per-clause top-level names:
    #{clause_summary}

    Fix: rename each clause to use one consistent name at position #{idx} (and any other \
    disagreeing positions). For shape-dependent contracts, use the `~>` implication \
    operator — e.g. `@pre is_binary(resource) ~> String.length(resource) <= 10`.

    Per-clause contracts may be added in a future Bond release. If this restriction \
    bites real code, please open an issue.\
    """
  end

  defp format_name(nil), do: "_"
  defp format_name(name) when is_atom(name), do: Atom.to_string(name)

  @doc """
  Rewrites a clause's params for use as a wrapper head, in two steps:

    1. **Canonical-name binding.** At each position, ensure the param binds the
       canonical name from `canonical_names`. If the user's pattern already
       does (e.g. clause head is `def f(stack, ...)` and canonical is `stack`),
       leave it alone. If the position is a wildcard (`_`), replace it with the
       canonical name. Otherwise wrap as `canonical = <original_pattern>` so
       the canonical name binds the whole position while the original
       destructure / literal pattern still pattern-matches.

    2. **Underscore-prefix unused names.** Any bound variable other than the
       canonical names (and any extra names passed in `used`) is underscore-
       prefixed so Elixir doesn't warn about it being unused in the wrapper
       body. The canonical names are always treated as used.

  Used by per-clause wrapper emission in `Bond.Compiler.ClauseWrapper`.
  """
  @spec rewrite_clause_params([Macro.t()], [atom()], MapSet.t(atom()) | Enumerable.t()) ::
          [Macro.t()]
  def rewrite_clause_params(params, canonical_names, used \\ [])
      when is_list(params) and is_list(canonical_names) do
    used_set =
      used
      |> MapSet.new()
      |> MapSet.union(MapSet.new(canonical_names))

    params
    |> Enum.with_index()
    |> Enum.map(fn {param, idx} ->
      canonical = Enum.at(canonical_names, idx)
      bound = bind_canonical_at_pos(param, canonical)
      underscore_prefix_unused(bound, used_set)
    end)
  end

  defp bind_canonical_at_pos(param, canonical) when is_atom(canonical) do
    case top_level_names([param]) do
      [^canonical] ->
        # Already binds the canonical name at top level. No rewrite needed.
        param

      [nil] ->
        # No top-level binding at this position. Add one.
        case param do
          {:_, meta, ctx} when is_atom(ctx) ->
            # Wildcard `_`: replace with the canonical var.
            {canonical, meta, ctx}

          _ ->
            # Destructure / literal / other: wrap as `canonical = <original>`.
            {:=, [], [Macro.var(canonical, nil), param]}
        end

      [_other_name] ->
        # User bound a different name at top level than canonical. Pre-0.17.2
        # this couldn't happen — `assert_clauses_agree!/3` strictly required
        # every position's name to match across clauses. Under the 0.17.2
        # relaxation, this DOES happen at unreferenced positions (the
        # canonical there is a generated `bond_arg_<idx>` regardless of what
        # the user named the param).
        #
        # Wrap as `canonical = <original>` so the wrapper binds the canonical
        # name; the user's name still binds too, via the original pattern.
        {:=, [], [Macro.var(canonical, nil), param]}
    end
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

  # `param \\ default` — default-arg form. Recurse on the inner param so the
  # caller doesn't have to `strip_default_args` first.
  defp top_level_name({:\\, _meta, [param, _default]}) do
    top_level_name(param)
  end

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
