defmodule Bond.Compiler.Invariants do
  @moduledoc internal: true
  @moduledoc """
  Emission logic for `@invariant`s.

  Lives in its own module (rather than inside `Bond.Compiler.AnnotatedFunction`) for two
  reasons:

    1. **Separation of concerns.** `AnnotatedFunction` owns the data model — clauses,
       per-function assertions, doc attributes, the override decision. The invariant emission
       is its own concern: detecting the struct-bearing argument, building the lifted defp,
       producing the pre-/post-invariant call sites. Keeping these apart makes both files
       easier to read.

    2. **Compilation order.** Growing `AnnotatedFunction` past a certain size shifted it
       later in the parallel-compile schedule, which raced with the test-support modules
       starting their own compilation. Splitting the emission logic out of
       `AnnotatedFunction` keeps that file smaller and avoids the race.

  The functions here are called from `Bond.Compiler.AnnotatedFunction.apply_contract/2` at
  the user module's `__before_compile__` time, and produce AST that's spliced into the
  user's module override clause.
  """

  alias Bond.Compiler.Assertion

  @typedoc """
  Descriptor for a single struct-bearing parameter in a function head.

    * `{:bound, var_name, param_index}` — the parameter is bound to a variable in the head
      (via `%__MODULE__{} = name`, `name = %__MODULE__{}`, or a bare `name` with an
      `is_struct(name, __MODULE__)` guard somewhere in the guard list, including inside
      compound `and`/`or` expressions). `param_index` is 0-based.

    * `{:destructure, param_index}` — the parameter destructures `%__MODULE__{...}` but
      does not bind the whole struct to a variable. Invariant emission rewrites the
      override clause head at this position to capture the struct under a generated name.
  """
  @type struct_param ::
          {:bound, atom(), non_neg_integer()}
          | {:destructure, non_neg_integer()}

  @doc """
  Finds every struct-bearing parameter in a function head, in left-to-right order.

  Returns a list of `t:struct_param/0` descriptors. Returns `[]` when no parameter and
  no guard mentions the module's struct.

  Recognised patterns:

    * `%__MODULE__{} = name` (or destructure-and-bind, e.g. `%__MODULE__{field: x} = name`)
    * `name = %__MODULE__{}` (reversed)
    * bare `name` plus `is_struct(name, __MODULE__)` somewhere in the guards, including
      inside arbitrary nesting of `and` / `or`
    * `%__MODULE__{...}` destructure with no `= name` — returned as `{:destructure, idx}`

  Multiple struct parameters in the same head (e.g. `def merge(%__MODULE__{} = a,
  %__MODULE__{} = b)`) all appear in the result.

  Fully-qualified module patterns (`%MyMod{}`) and aliased forms are not recognised —
  invariants are scoped to the struct's own defining module, so `__MODULE__` is the
  idiomatic form.
  """
  @spec detect_struct_params([Macro.t()], [Macro.t()]) :: [struct_param()]
  def detect_struct_params(params, guards) when is_list(params) and is_list(guards) do
    guard_vars = collect_guard_struct_vars(guards)

    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, idx} ->
      case classify_param(param, guard_vars) do
        {:bound, name} -> [{:bound, name, idx}]
        :destructure -> [{:destructure, idx}]
        :none -> []
      end
    end)
  end

  @doc """
  Resolves the per-function invariant mode given the per-module config value and the
  annotated function's `:kind` and `:invariants` list.

  Returns `:purge` when:

    * the user explicitly purged invariants, OR
    * the function is `defp` (private functions are exempt by the Eiffel convention), OR
    * the module has no `@invariant`s registered.

  Otherwise returns the supplied `true`/`false` mode unchanged.
  """
  @spec resolve_mode(mode :: Bond.Compiler.AnnotatedFunction.mode(), :def | :defp, list()) ::
          Bond.Compiler.AnnotatedFunction.mode()
  def resolve_mode(:purge, _kind, _invariants), do: :purge
  def resolve_mode(_value, :defp, _invariants), do: :purge
  def resolve_mode(_value, _kind, []), do: :purge
  def resolve_mode(value, _kind, _invariants) when value in [true, false], do: value

  @doc """
  Returns `true` when at least one clause in the given list has SOME invariant-
  check mechanism — either:

    * its head pattern-matches the struct (pre-invariant fires on entry), or
    * its body statically returns the struct or `{:ok, struct}` (post-invariant
      fires on exit).

  Returns `false` when no clause has either mechanism, meaning invariants are
  fully skipped for the function — the footgun `:warn_skipped_invariants` warns
  about.

  Used by `Bond.Compiler.AnnotatedFunction.apply_contract/2` to decide whether to
  emit the warning at the function definition site. The post-invariant body
  heuristic is intentionally conservative: it detects the common constructor
  shapes (`%__MODULE__{...}`, `{:ok, %__MODULE__{...}}`, and the same as the last
  expression in a block) but not function calls or branching expressions whose
  return shape can't be determined statically. Users with constructors that
  build the struct via a helper call still suppress with
  `@bond_warn_skipped_invariants false`.
  """
  @spec any_clause_checks_invariants?([term()], module()) :: boolean()
  def any_clause_checks_invariants?(clauses, struct_module) when is_list(clauses) do
    Enum.any?(clauses, fn clause ->
      detect_struct_params(clause.params || [], clause.guards || []) != [] or
        body_returns_struct?(clause.body, struct_module)
    end)
  end

  # Detects whether a function clause's body statically returns the struct (so
  # the runtime post-invariant check will fire). Returns true for:
  #
  #   - direct: `%__MODULE__{...}`
  #   - wrapped: `{:ok, %__MODULE__{...}}`
  #   - block-bodied versions of either (last expression of a `:__block__`)
  #
  # `struct_module` is passed through for future extension (e.g. detecting
  # `%MyMod{...}` aliases), but is currently unused — Bond's idiomatic form
  # for invariant-declaring modules is `%__MODULE__{...}` (see
  # `detect_struct_params/2`'s @doc).
  defp body_returns_struct?([{:do, expr} | _], struct_module) do
    expression_returns_struct?(expr, struct_module)
  end

  defp body_returns_struct?(_body, _struct_module), do: false

  defp expression_returns_struct?({:__block__, _, statements}, struct_module) do
    case List.last(statements) do
      nil -> false
      last -> expression_returns_struct?(last, struct_module)
    end
  end

  defp expression_returns_struct?({:%, _, [{:__MODULE__, _, _}, _]}, _struct_module), do: true

  defp expression_returns_struct?({:ok, inner}, struct_module) do
    expression_returns_struct?(inner, struct_module)
  end

  defp expression_returns_struct?(_expr, _struct_module), do: false

  @doc """
  Detects every struct-bearing parameter in a function clause, or returns `[]` when
  invariants are purged for the function.

  Wrapper around `detect_struct_params/2` that respects the resolved invariant `mode`.
  Kept in this module to keep `Bond.Compiler.AnnotatedFunction` small (see the compile-
  order gotcha note in the moduledoc).
  """
  @spec struct_params_for_clause(Bond.Compiler.AnnotatedFunction.mode(), term()) ::
          [struct_param()]
  def struct_params_for_clause(:purge, _clause), do: []

  def struct_params_for_clause(_mode, clause) do
    detect_struct_params(clause.params || [], clause.guards || [])
  end

  @doc """
  Emits one pre-invariant statement per detected struct parameter, in left-to-right
  order. Each statement calls the lifted invariants defp with the appropriate variable:

    * `{:bound, var, _}` — the bound variable from the function head.
    * `{:destructure, idx}` — `__bond_subject_<idx>__`, which the override clause head
      binds via `Invariants.rewrite_call_params/2`.

  The defp rebinds `subject` to that value and runs every `@invariant` assertion
  against it. Returns `[]` when the kind is purged or when no struct parameters were
  detected.
  """
  @spec all_pre_invariant_stmts(
          atom(),
          [struct_param()],
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: [Macro.t()]
  def all_pre_invariant_stmts(_name, _params, :purge, _pre_mode, _post_mode), do: []
  def all_pre_invariant_stmts(_name, [], _mode, _pre_mode, _post_mode), do: []

  def all_pre_invariant_stmts(name, struct_params, mode, pre_mode, post_mode) do
    chain = %{preconditions: pre_mode, postconditions: post_mode}

    for sp <- struct_params do
      arg_var = subject_var(sp)

      # `__opaque__` widens the subject's narrowed type at the lifted-defp call boundary —
      # without this, an `@invariant` like `subject.capacity >= 0` on a `non_neg_integer()`
      # field would let Dialyzer prove `and`/`or` branches in the assertion expression dead
      # under a `pattern_match` warning. Same motivation as
      # `Bond.Compiler.ClauseWrapper.opaque_args/1`.
      quote do
        if Bond.Runtime.Eval.should_evaluate?(
             :invariants,
             unquote(mode),
             unquote(Macro.escape(chain))
           ) do
          Bond.Runtime.Eval.evaluate_invariants(fn ->
            unquote(name)(Bond.Predicates.__opaque__(unquote(arg_var)))
          end)
        end
      end
    end
  end

  @doc """
  Rewrites a function's parameter list to capture every `{:destructure, idx}` struct
  parameter under a generated variable name (`__bond_subject_<idx>__`), so the override
  clause's head, lifted defps, and `super`/eval call sites can refer to the captured
  value rather than re-evaluating the destructure pattern.

  Returns `{head_params, call_args}`:

    * `head_params` — patterns intended for use in `def`/`defp` heads. For destructure
      positions, the pattern is wrapped as `<original_pattern> = __bond_subject_<idx>__`
      so it still pattern-matches the same shape but also binds the whole struct.
    * `call_args` — values intended for use in `super(...)` / lifted-defp call sites.
      For destructure positions, the value is the captured variable. For all other
      positions, both lists contain the original parameter.

  Without this rewrite, `super(<destructure_pattern>)` is broken: an expression like
  `super(%__MODULE__{items: [h | _]})` tries to *construct* a new struct from the
  destructure pattern's AST, which fails at compile time on `_` and silently produces
  the wrong struct in benign cases. The capturing rewrite passes the original input
  through unchanged.
  """
  @spec rewrite_call_params([Macro.t()], [struct_param()]) ::
          {head_params :: [Macro.t()], call_args :: [Macro.t()]}
  def rewrite_call_params(params, struct_params) do
    destructure_indices = MapSet.new(for {:destructure, idx} <- struct_params, do: idx)

    params
    |> Enum.with_index()
    |> Enum.map(fn {param, idx} ->
      if MapSet.member?(destructure_indices, idx) do
        capture = Macro.var(:"__bond_subject_#{idx}__", nil)
        {quote(do: unquote(param) = unquote(capture)), capture}
      else
        {param, param}
      end
    end)
    |> Enum.unzip()
  end

  defp subject_var({:bound, var, _idx}), do: Macro.var(var, nil)
  defp subject_var({:destructure, idx}), do: Macro.var(:"__bond_subject_#{idx}__", nil)

  @doc """
  Convenience wrapper that produces every parameter-derived value
  `Bond.Compiler.AnnotatedFunction.build_contract_override/4` needs in a single call:

    * `struct_params` — `[t:struct_param/0]` for the clause, or `[]` when purged.
    * `head_params` — patterns for `def`/`defp` heads (destructure positions augmented
      with capturing bindings).
    * `super_args` — values for `super(...)` and lifted-defp call sites (captured
      variables at destructure positions, original parameters elsewhere).

  Lives here so `AnnotatedFunction` stays small (see the compile-order gotcha note in
  the moduledoc).
  """
  @spec params_split([Macro.t()], term(), Bond.Compiler.AnnotatedFunction.mode()) ::
          {[struct_param()], [Macro.t()], [Macro.t()]}
  def params_split(clean_params, first_clause, inv_mode) do
    struct_params = struct_params_for_clause(inv_mode, first_clause)
    {head_params, super_args} = rewrite_call_params(clean_params, struct_params)
    {struct_params, head_params, super_args}
  end

  @doc """
  Emits the post-invariant case-extraction statements that go *after* the postconditions
  and before the return.

  Delegates the `%<struct_module>{}` / `{:ok, %<struct_module>{}}` shape match to
  `Bond.Runtime.Eval.check_struct_invariant/3` rather than emitting a `case var!(result)`
  into the user's module. Emitting that `case` here lets Elixir's type checker (1.18+)
  prove the struct clauses unreachable for functions that return other shapes (e.g. a
  `size/1` returning an integer), producing "the following clause will never match"
  warnings that fail `--warnings-as-errors` in downstream builds. Doing the match in
  `Eval` (where `result` is typed `term()`) keeps the runtime behaviour identical while
  emitting no shape-match into the using module. The struct module is unquoted in rather
  than spelled `%__MODULE__{}` to avoid a deferred-`__MODULE__` reference that confuses
  parallel compilation.

  The runtime `should_evaluate?/3` gate stays at the call site so the bridging closure is
  allocated only when invariants are actually evaluated.
  """
  @spec post_invariant_stmts(
          atom(),
          Bond.Compiler.AnnotatedFunction.mode(),
          module(),
          Bond.Compiler.AnnotatedFunction.mode(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: [Macro.t()]
  def post_invariant_stmts(_name, :purge, _struct_module, _pre_mode, _post_mode), do: []

  def post_invariant_stmts(name, mode, struct_module, pre_mode, post_mode) do
    chain = %{preconditions: pre_mode, postconditions: post_mode}

    # `__opaque__` widens the post-extracted subject's type at the lifted-defp call
    # boundary — see the corresponding comment in `all_pre_invariant_stmts/5`.
    [
      quote do
        if Bond.Runtime.Eval.should_evaluate?(
             :invariants,
             unquote(mode),
             unquote(Macro.escape(chain))
           ) do
          Bond.Runtime.Eval.check_struct_invariant(
            var!(result),
            unquote(struct_module),
            fn __bond_post_value__ ->
              unquote(name)(Bond.Predicates.__opaque__(__bond_post_value__))
            end
          )
        end
      end
    ]
  end

  @doc """
  Builds the lifted `defp __bond_invariants__<fun>__<arity>(value)` that the pre- and
  post-invariant call sites delegate to. Returns `nil` when invariants are purged.
  """
  @spec build_lifted_defp(
          atom(),
          [Assertion.t(:invariant)],
          Assertion.function_info(),
          Macro.Env.t(),
          Bond.Compiler.AnnotatedFunction.mode()
        ) :: Macro.t() | nil
  def build_lifted_defp(_name, _invariants, _function_info, _env, :purge), do: nil

  def build_lifted_defp(name, invariants, function_info, env, _mode) do
    body = Assertion.invariants_body(invariants, function_info)

    quote file: env.file, line: env.line do
      defp unquote(name)(var!(bond_invariant_value)) do
        unquote(body)
      end
    end
  end

  defp classify_param(param, guard_vars) do
    case param do
      {:=, _, [{:%, _, [{:__MODULE__, _, _}, _]}, {var, _, ctx}]}
      when is_atom(var) and is_atom(ctx) ->
        {:bound, var}

      {:=, _, [{var, _, ctx}, {:%, _, [{:__MODULE__, _, _}, _]}]}
      when is_atom(var) and is_atom(ctx) ->
        {:bound, var}

      {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
        if MapSet.member?(guard_vars, var), do: {:bound, var}, else: :none

      {:%, _, [{:__MODULE__, _, _}, _]} ->
        :destructure

      _ ->
        :none
    end
  end

  defp collect_guard_struct_vars(guards) do
    guards
    |> Enum.flat_map(&walk_guard_for_is_struct/1)
    |> MapSet.new()
  end

  defp walk_guard_for_is_struct({:is_struct, _, [{var, _, ctx}, {:__MODULE__, _, _}]})
       when is_atom(var) and is_atom(ctx) do
    [var]
  end

  defp walk_guard_for_is_struct({op, _, [left, right]}) when op in [:and, :or] do
    walk_guard_for_is_struct(left) ++ walk_guard_for_is_struct(right)
  end

  defp walk_guard_for_is_struct(_), do: []
end
