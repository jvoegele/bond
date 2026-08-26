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

    2. **Size.** `AnnotatedFunction` is large enough already; the emission logic is the
       cleanest slice to move out of it.

  This split was originally made for a third reason — growing `AnnotatedFunction` shifted it
  later in the parallel-compile schedule, racing the test-support modules — which no longer
  applies. Compilation order is now guaranteed outright by the `Code.ensure_compiled!/1` chain
  (see `Bond.__using__/1`), so file size is a readability concern here, not a correctness one.

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

  The struct may be named as `__MODULE__`, spelled out (`%MyApp.Cart{}`), or reached
  through an alias in scope (`alias __MODULE__` then `%Cart{}`). `same_module?/3`
  resolves all three exactly, using the module's own alias table; see its comment for why
  emission cannot use the looser `module_reference?/2` that the warning heuristic relies
  on.

  Before #93 only the literal `__MODULE__` form was recognised, so every other spelling
  silently lost its entry check *and* escaped the `:warn_skipped_invariants` warning —
  the warning's heuristic resolved names this function did not, so it concluded the
  function was fine.
  """
  @spec detect_struct_params([Macro.t()], [Macro.t()], module(), keyword()) :: [struct_param()]
  def detect_struct_params(params, guards, struct_module, aliases \\ [])
      when is_list(params) and is_list(guards) do
    guard_vars = collect_guard_struct_vars(guards, struct_module, aliases)

    params
    |> Enum.with_index()
    |> Enum.flat_map(fn {param, idx} ->
      case classify_param(param, guard_vars, struct_module, aliases) do
        {:bound, name} ->
          [{:bound, name, idx}]

        :destructure ->
          [{:destructure, idx}]

        :none ->
          # The parameter is not itself the struct, but may carry one inside a tuple,
          # map, or list pattern (#84). Any name the head binds to the struct at depth
          # is checked, in left-to-right traversal order.
          for var <- nested_struct_vars(param, struct_module, aliases), do: {:bound, var, idx}
      end
    end)
  end

  @doc """
  Collects every name a head pattern binds to this module's struct *below* the top level,
  in left-to-right order (#84).

  `def log({:wrapped, %__MODULE__{} = s})` binds `s` to the struct one level down. The
  entry check can use it directly — the wrapper reproduces the user's pattern, so `s` is
  in scope — but only if `s` survives `Clauses.rewrite_clause_params/3`, which
  underscore-prefixes head names the wrapper body does not reference. `ClauseWrapper`
  calls this *before* the rewrite so these names can join the exclusion set, the same way
  guard-referenced names do.

  Only bound structs are returned. A destructure-only nested pattern
  (`{:wrapped, %__MODULE__{v: v}}`) binds nothing to check against and is not reported —
  see the guide's head-shape table.
  """
  @spec nested_struct_vars(Macro.t(), module(), keyword()) :: [atom()]
  def nested_struct_vars(param, struct_module, aliases \\ []) do
    {_ast, bindings} =
      Macro.prewalk(param, [], fn
        {:=, _, [{var, _, ctx}, rhs]} = node, acc when is_atom(var) and is_atom(ctx) ->
          if struct_pattern?(rhs, struct_module, aliases),
            do: {node, [var | acc]},
            else: {node, acc}

        {:=, _, [lhs, {var, _, ctx}]} = node, acc when is_atom(var) and is_atom(ctx) ->
          if struct_pattern?(lhs, struct_module, aliases),
            do: {node, [var | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    # Everything on the parameter's own top-level `=` chain belongs to the top-level
    # path, which already owns it — including the inner name of the
    # `canonical = (%__MODULE__{} = user_var)` shape that `rewrite_clause_params/3`
    # produces, whose inner name is deliberately underscore-prefixed as unused. Only
    # bindings reached through a container (tuple, map, list) are nested.
    (bindings -- top_chain_vars(param)) |> Enum.reverse() |> Enum.uniq()
  end

  defp top_chain_vars({:=, _, [lhs, rhs]}), do: top_chain_vars(lhs) ++ top_chain_vars(rhs)
  defp top_chain_vars({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: [var]
  defp top_chain_vars(_ast), do: []

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
  return shape can't be determined statically. `any_clause_mentions_struct?/2` is
  the wider net that keeps that conservatism from producing false warnings.
  """
  @spec any_clause_checks_invariants?([term()], module(), keyword()) :: boolean()
  def any_clause_checks_invariants?(clauses, struct_module, aliases \\ [])
      when is_list(clauses) do
    Enum.any?(clauses, fn clause ->
      detect_struct_params(clause.params || [], clause.guards || [], struct_module, aliases) !=
        [] or
        body_returns_struct?(clause.body, struct_module, aliases)
    end)
  end

  @doc """
  Returns `true` when the struct appears *anywhere* in any clause — head, guards,
  or body — as a `%Struct{}` pattern/literal or a `struct/2`/`struct!/2` call
  naming the module.

  This is deliberately wider than `any_clause_checks_invariants?/2`, and it exists
  because the two questions are not the same one (#80):

    * `any_clause_checks_invariants?/2` asks "can Bond *prove* a check fires?",
      which drives nothing at runtime — it is a static approximation.
    * The post-invariant check is emitted unconditionally and matches the return
      value's shape at runtime (see `post_invariant_stmts/5`), so a function that
      returns the struct by *any* means has its invariants checked on exit,
      whether or not the static heuristic could see it.

  That gap made the warning fire on functions whose invariants demonstrably do
  run: a struct matched inside a tuple (`def unwrap({:wrapped, %__MODULE__{} = s}),
  do: s`), a constructor built with `struct/2`, one returned out of a `case`. A
  warning that cries wolf gets suppressed wholesale, taking the true positives
  with it — so the warning now fires only when the struct is not mentioned at all,
  which is the case where invariants are genuinely, entirely skipped.

  Erring toward silence is the right bias here: a missed warning costs one
  unchecked function, while a false one costs trust in every warning.
  """
  @spec any_clause_mentions_struct?([term()], module()) :: boolean()
  def any_clause_mentions_struct?(clauses, struct_module) when is_list(clauses) do
    Enum.any?(clauses, fn clause ->
      asts = (clause.params || []) ++ (clause.guards || []) ++ clause_body_asts(clause.body)
      Enum.any?(asts, &mentions_struct?(&1, struct_module))
    end)
  end

  @doc """
  Returns `true` when some clause's every return path is a call to another **public**
  function of the same module (#111).

  A function that delegates has no struct in its head and may never name the struct at all,
  so both checks above miss it — while the value it returns has been through the sibling's
  own entry and exit checks one hop away, and through this function's exit check on the way
  out. Warning there pushes the author toward inlining the struct literal, duplicating the
  normalisation the builder exists to hold in one place. That is the linter arguing for a
  worse design, which is the opposite of its purpose.

  Deliberately narrow in three ways:

    * **Public siblings only.** A call to a public function of an invariant-declaring module
      reaches something that enforces the invariant itself. A `defp` carries no such
      guarantee, and invariants are not woven into one.
    * **Return position only.** A function that merely *calls* a sibling somewhere in its
      body is not delegating. Keeping the distinction preserves what this warning turns out
      to be unexpectedly good at: flagging a public function that has nothing to do with the
      module's struct and is squatting in its namespace.
    * **Not itself.** A tail call to the same function says nothing about what comes back.

  One hop is enough. Chasing further would need the callee's body, which at
  `@before_compile` belongs to a function Bond may not have finished processing.
  """
  @spec any_clause_delegates?([term()], MapSet.t(), {atom(), non_neg_integer()}) :: boolean()
  def any_clause_delegates?(clauses, public_defs, self) when is_list(clauses) do
    Enum.any?(clauses, fn clause ->
      case clause.body |> clause_body_asts() |> Enum.flat_map(&return_expressions/1) do
        [] -> false
        returns -> Enum.all?(returns, &local_public_call?(&1, public_defs, self))
      end
    end)
  end

  # The expressions a body can evaluate to, following the branching forms into their own
  # return positions. Anything else is its own return expression.
  defp return_expressions({:__block__, _meta, exprs}) do
    case List.last(exprs) do
      nil -> []
      last -> return_expressions(last)
    end
  end

  defp return_expressions({form, _meta, [_subject, branches]})
       when form in [:if, :unless] and is_list(branches) do
    Enum.flat_map(branches, fn {_key, ast} -> return_expressions(ast) end)
  end

  defp return_expressions({form, _meta, args}) when form in [:case, :cond, :with] do
    case List.last(args) do
      branches when is_list(branches) ->
        Enum.flat_map(branches, fn
          {_key, clauses} when is_list(clauses) -> Enum.flat_map(clauses, &clause_returns/1)
          {_key, ast} -> return_expressions(ast)
        end)

      _other ->
        []
    end
  end

  defp return_expressions(other), do: [other]

  defp clause_returns({:->, _meta, [_pattern, body]}), do: return_expressions(body)
  defp clause_returns(_other), do: []

  defp local_public_call?({name, _meta, args}, public_defs, self)
       when is_atom(name) and is_list(args) do
    pair = {name, length(args)}
    pair != self and MapSet.member?(public_defs, pair)
  end

  defp local_public_call?(_other, _public_defs, _self), do: false

  defp clause_body_asts(body) when is_list(body), do: Enum.map(body, fn {_key, ast} -> ast end)
  defp clause_body_asts(_body), do: []

  defp mentions_struct?(ast, struct_module) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        node, false -> {node, struct_reference?(node, struct_module)}
      end)

    found?
  end

  # `%__MODULE__{...}` / `%Struct{...}`, in a pattern or an expression.
  defp struct_reference?({:%, _, [name | _]}, struct_module),
    do: module_reference?(name, struct_module)

  # `struct(__MODULE__, ...)` / `struct!(Struct, ...)`, the common dynamic
  # constructor. Both the bare and `Kernel.`-qualified forms.
  defp struct_reference?({fun, _, [name | _]}, struct_module) when fun in [:struct, :struct!],
    do: module_reference?(name, struct_module)

  defp struct_reference?({{:., _, [{:__aliases__, _, [:Kernel]}, fun]}, _, [name | _]}, mod)
       when fun in [:struct, :struct!],
       do: module_reference?(name, mod)

  defp struct_reference?(_node, _struct_module), do: false

  # `__MODULE__` is the idiomatic form inside the struct's own module; an explicit
  # alias is accepted too, matched on the trailing segments so `MyApp.Cart` and a
  # locally-aliased `Cart` both resolve.
  defp module_reference?({:__MODULE__, _, _}, _struct_module), do: true

  defp module_reference?({:__aliases__, _, segments}, struct_module)
       when is_list(segments) do
    struct_segments = Module.split(struct_module) |> Enum.map(&String.to_atom/1)

    Enum.all?(segments, &is_atom/1) and
      List.starts_with?(Enum.reverse(struct_segments), Enum.reverse(segments))
  end

  defp module_reference?(module, struct_module) when is_atom(module), do: module == struct_module
  defp module_reference?(_name, _struct_module), do: false

  # Strict counterpart to `module_reference?/2`, for deciding whether to *emit* an
  # invariant check rather than whether to stay quiet about one (#93).
  #
  # `module_reference?/2` matches an alias on its trailing segments, which is right for
  # the `:warn_skipped_invariants` heuristic — over-matching there only suppresses a
  # warning. Emission cannot afford it: Elixir does not auto-alias a module's own last
  # segment, so inside `MyApp.Cart` the pattern `%Cart{}` refers to `Elixir.Cart`, a
  # different struct. Binding `subject` to it would evaluate the invariant against the
  # wrong value.
  #
  # So this resolves exactly, against the module's real alias table (threaded down from
  # `env.aliases` at `__before_compile__`): `__MODULE__`, a name that the alias table or
  # plain concatenation maps to the struct module, or an already resolved atom. An alias
  # pointing at some *other* module correctly does not match.
  defp same_module?({:__MODULE__, _, _}, _struct_module, _aliases), do: true

  defp same_module?({:__aliases__, _, [head | rest] = segments}, struct_module, aliases)
       when is_atom(head) do
    Enum.all?(segments, &is_atom/1) and resolve_alias(head, rest, aliases) == struct_module
  end

  defp same_module?(module, struct_module, _aliases) when is_atom(module),
    do: module == struct_module

  defp same_module?(_name, _struct_module, _aliases), do: false

  # Resolves an `__aliases__` head against the module's alias table, the way Elixir
  # itself would. `alias __MODULE__` in `MyApp.Cart` puts `{Cart, MyApp.Cart}` in the
  # table, so `%Cart{}` resolves to `MyApp.Cart`; with no such alias it resolves to
  # `Elixir.Cart`, which is a different module and correctly does not match.
  defp resolve_alias(head, rest, aliases) do
    base = Module.concat([head])

    case List.keyfind(aliases || [], base, 0) do
      {^base, target} -> Module.concat([target | rest])
      _ -> Module.concat([head | rest])
    end
  end

  # Detects whether a function clause's body statically returns the struct (so
  # the runtime post-invariant check will fire). Returns true for:
  #
  #   - direct: `%__MODULE__{...}`
  #   - wrapped: `{:ok, %__MODULE__{...}}`
  #   - block-bodied versions of either (last expression of a `:__block__`)
  #
  # The struct may be named as `__MODULE__` or by the module's own name;
  # `module_reference?/2` decides, matching head detection (#93).
  defp body_returns_struct?([{:do, expr} | _], struct_module, aliases) do
    expression_returns_struct?(expr, struct_module, aliases)
  end

  defp body_returns_struct?(_body, _struct_module, _aliases), do: false

  defp expression_returns_struct?({:__block__, _, statements}, struct_module, aliases) do
    case List.last(statements) do
      nil -> false
      last -> expression_returns_struct?(last, struct_module, aliases)
    end
  end

  defp expression_returns_struct?({:%, _, [name, _]}, struct_module, aliases),
    do: same_module?(name, struct_module, aliases)

  defp expression_returns_struct?({:ok, inner}, struct_module, aliases) do
    expression_returns_struct?(inner, struct_module, aliases)
  end

  defp expression_returns_struct?(_expr, _struct_module, _aliases), do: false

  @doc """
  Returns the clauses whose body statically returns a **tuple** carrying the struct in a position
  the exit check will not look at (#131).

  `Bond.Runtime.Eval.check_struct_invariant/3` extracts a subject from `%Struct{}` or
  `{:ok, %Struct{}}` and lets every other shape through unchecked. `{batch, struct}` is an
  ordinary Elixir return, so the value the caller keeps — often from the *last* call of a run,
  which has no next call to catch it on entry — is never validated.

  Detection is deliberately narrow, because the bias for this family of warnings is silence (see
  `any_clause_mentions_struct?/2`): a tuple **literal**, not the `{:ok, _}` shape, with at least
  one element that is unmistakably this struct — a `%Struct{}` literal, or a `%{var | ...}`
  update of a variable the head bound as a struct parameter. A tuple built by a function call, or
  holding a struct arrived at some other way, is not reported.

  Making the check itself fire on these shapes is a behaviour change, and `guides/stability.md`
  puts that in the next major with a warning in a minor first. This is that warning.
  """
  @spec clauses_returning_unchecked_struct([term()], module(), keyword()) :: [term()]
  def clauses_returning_unchecked_struct(clauses, struct_module, aliases \\ [])
      when is_list(clauses) do
    Enum.filter(clauses, fn clause ->
      bound = struct_param_vars(clause, struct_module, aliases)
      body_returns_unchecked_tuple?(clause.body, struct_module, aliases, bound)
    end)
  end

  defp struct_param_vars(clause, struct_module, aliases) do
    clause.params
    |> Kernel.||([])
    |> detect_struct_params(clause.guards || [], struct_module, aliases)
    |> Enum.flat_map(fn
      {:bound, var, _idx} -> [var]
      _other -> []
    end)
    |> MapSet.new()
  end

  defp body_returns_unchecked_tuple?([{:do, expr} | _], struct_module, aliases, bound) do
    expr
    |> last_expression()
    |> unchecked_tuple?(struct_module, aliases, bound)
  end

  defp body_returns_unchecked_tuple?(_body, _struct_module, _aliases, _bound), do: false

  defp last_expression({:__block__, _, statements}),
    do: statements |> List.last() |> last_expression()

  defp last_expression(expr), do: expr

  # `{:ok, x}` is the shape the exit check already handles; anything else two-element is a bare
  # AST tuple, and larger tuples arrive as `{:{}, _, elements}`.
  defp unchecked_tuple?({:ok, _inner}, _struct_module, _aliases, _bound), do: false

  defp unchecked_tuple?({:{}, _, elements}, struct_module, aliases, bound) do
    Enum.any?(elements, &confident_struct?(&1, struct_module, aliases, bound))
  end

  defp unchecked_tuple?({left, right}, struct_module, aliases, bound) do
    confident_struct?(left, struct_module, aliases, bound) or
      confident_struct?(right, struct_module, aliases, bound)
  end

  defp unchecked_tuple?(_expr, _struct_module, _aliases, _bound), do: false

  defp confident_struct?({:%, _, [name, _]}, struct_module, aliases, _bound),
    do: same_module?(name, struct_module, aliases)

  # `%{p | field: v}` where `p` is a parameter the head matched as this struct.
  defp confident_struct?({:%{}, _, [{:|, _, [{var, _, ctx}, _updates]}]}, _sm, _aliases, bound)
       when is_atom(var) and is_atom(ctx),
       do: MapSet.member?(bound, var)

  defp confident_struct?(_expr, _struct_module, _aliases, _bound), do: false

  @doc """
  Emits one pre-invariant statement per detected struct parameter, in left-to-right
  order. Each statement calls the lifted invariants defp with the appropriate variable:

    * `{:bound, var, _}` — the bound variable from the function head.
    * `{:destructure, idx}` — `__bond_subject_<idx>__`, the captured-struct variable
      for a destructure-only position.

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

      # The lifted invariant defp carries `@dialyzer {:nowarn_function, ...}` (see
      # `build_lifted_defp/5`), so the subject's narrowed type can flow in unwrapped:
      # any `pattern_match` warning from an `@invariant` duplicating a field's typespec
      # (e.g. `subject.capacity >= 0` on a `non_neg_integer()` field) is suppressed at
      # the defp rather than laundered at the call boundary.
      quote do
        if Bond.Runtime.Eval.should_evaluate?(
             :invariants,
             unquote(mode),
             unquote(Macro.escape(chain))
           ) do
          Bond.Runtime.Eval.evaluate_invariants(fn ->
            unquote(name)(unquote(arg_var))
          end)
        end
      end
    end
  end

  defp subject_var({:bound, var, _idx}), do: Macro.var(var, nil)
  defp subject_var({:destructure, idx}), do: Macro.var(:"__bond_subject_#{idx}__", nil)

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

    # The post-extracted subject flows into the lifted defp unwrapped; the defp's
    # `@dialyzer {:nowarn_function, ...}` suppresses any narrowed-type warning — see
    # the corresponding note in `all_pre_invariant_stmts/5`.
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
              unquote(name)(__bond_post_value__)
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
      # Suppress Dialyzer warnings for this generated defp instead of widening the
      # caller's argument types through `Bond.Predicates.__opaque__/1`. An `@invariant`
      # that duplicates a field's typespec-implied fact makes `and`/`or` branches in the
      # assertion appear dead; nowarn silences that at zero runtime cost. The subject is
      # already `term()`-checked at the call site, so little real coverage is lost.
      @dialyzer {:nowarn_function, [{unquote(name), 1}]}
      defp unquote(name)(var!(bond_invariant_value)) do
        unquote(body)
      end
    end
  end

  defp classify_param(param, guard_vars, struct_module, aliases) do
    case param do
      # A match (`=`) with a top-level variable on one side and a struct match
      # (possibly nested) on the other. Binds the variable to the struct.
      #
      # The nested case matters because Bond's own per-clause wrapper rewrite
      # (`Clauses.rewrite_clause_params/3`) wraps a struct-binding head as
      # `canonical = (%__MODULE__{} = user_var)` whenever the canonical name at
      # that position is generated — which happens for multi-clause functions
      # whose clauses disagree on the position's name (e.g. a struct clause
      # alongside a binary clause). We bind the *outer* variable: it's the
      # canonical name the wrapper body references, while the inner one has been
      # underscore-prefixed as intentionally-unused.
      {:=, _, [{var, _, ctx}, rhs]} when is_atom(var) and is_atom(ctx) ->
        if struct_pattern?(rhs, struct_module, aliases), do: {:bound, var}, else: :none

      {:=, _, [lhs, {var, _, ctx}]} when is_atom(var) and is_atom(ctx) ->
        if struct_pattern?(lhs, struct_module, aliases), do: {:bound, var}, else: :none

      {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
        if MapSet.member?(guard_vars, var), do: {:bound, var}, else: :none

      {:%, _, [name, _]} ->
        if same_module?(name, struct_module, aliases), do: :destructure, else: :none

      _ ->
        :none
    end
  end

  # Does this pattern match the module's own struct, directly or along a chain of
  # `=` matches? `%__MODULE__{}`, `%__MODULE__{} = x`, and `a = (%__MODULE__{} = b)`
  # all qualify, as do the same shapes written with the module's own name
  # (`%Cart{}`, `%MyApp.Cart{}`, or a locally-aliased `%Cart{}`) — `module_reference?/2`
  # decides, so head detection and the `:warn_skipped_invariants` heuristic agree on
  # what counts as "this module's struct" (#93). An unrelated `%OtherMod{}` does not.
  defp struct_pattern?({:%, _, [name, _]}, struct_module, aliases),
    do: same_module?(name, struct_module, aliases)

  defp struct_pattern?({:=, _, [lhs, rhs]}, struct_module, aliases),
    do:
      struct_pattern?(lhs, struct_module, aliases) or
        struct_pattern?(rhs, struct_module, aliases)

  defp struct_pattern?(_, _struct_module, _aliases), do: false

  defp collect_guard_struct_vars(guards, struct_module, aliases) do
    guards
    |> Enum.flat_map(&walk_guard_for_is_struct(&1, struct_module, aliases))
    |> MapSet.new()
  end

  defp walk_guard_for_is_struct({:is_struct, _, [{var, _, ctx}, name]}, struct_module, aliases)
       when is_atom(var) and is_atom(ctx) do
    if same_module?(name, struct_module, aliases), do: [var], else: []
  end

  defp walk_guard_for_is_struct({op, _, [left, right]}, struct_module, aliases)
       when op in [:and, :or] do
    walk_guard_for_is_struct(left, struct_module, aliases) ++
      walk_guard_for_is_struct(right, struct_module, aliases)
  end

  defp walk_guard_for_is_struct(_, _struct_module, _aliases), do: []
end
