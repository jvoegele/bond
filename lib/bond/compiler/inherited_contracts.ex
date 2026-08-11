defmodule Bond.Compiler.InheritedContracts do
  @moduledoc internal: true
  @moduledoc """
  Shared compile-time plumbing for inherited contracts — the `@pre`/`@post` that
  `Bond.Behaviour` attaches to a behaviour's `@callback`s and `Bond.Protocol` attaches to a
  protocol's `def`s.

  Both flavours accumulate pending contracts as they encounter `@pre`/`@post`, attach them to a
  `{name, arity}` when the callback/function is declared, and validate that every name a contract
  references is one the operation actually binds. That machinery is identical; the few
  differences (diagnostic wording, the `source_behaviour` stamp, `old/1` rejection, the
  module-attribute keys) are carried in a `Bond.Compiler.InheritedContracts.Context` so this
  module stays flavour-agnostic.

  Each caller's own arg-spec parser stays put: a behaviour parses `name(a :: t) :: ret` callback
  specs, a protocol parses bare `def` argument lists — structurally different AST. Both produce a
  `[atom]` arg-names list (using the `:"bond_arg_<idx>"` convention for unnamed positions), and
  everything downstream of that list is shared here.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Clauses
  alias Bond.Compiler.InheritedContracts.Context

  @doc """
  Accumulates a pending `@pre`/`@post`. A keyword-list expression registers one labelled
  assertion per pair; a bare expression registers a single unlabelled assertion.
  """
  def accumulate_pending(%Context{} = ctx, kind, expression, %Macro.Env{} = env, meta) do
    if Keyword.keyword?(expression) do
      for {label, expr} <- expression, do: stash_assertion(ctx, kind, expr, label, env, meta)
      :ok
    else
      stash_assertion(ctx, kind, expression, nil, env, meta)
    end
  end

  @doc """
  Stashes the assertions scoped to one `where`/`whenever` binding form (#47) as pending contracts
  for the next callback/protocol function.

  Mirrors `Bond.Compiler.register_binding_group/7` for the inherited-contract path: each member
  becomes an ordinary pending `%Assertion{}` tagged with a shared binding group (so it round-trips
  through the behaviour/protocol reflection and re-materialises in the implementer via the same
  grouped codegen as a direct `@pre`/`@post`). `binder` is `:where` (asserts the shape) or
  `:whenever` (conditional); `binding_ast` is the `pattern = source` / `pattern <- source` clause;
  `scoped` is the remaining bare/labelled assertion args.
  """
  def accumulate_pending_binding_group(
        %Context{} = ctx,
        kind,
        binder,
        binding_ast,
        scoped,
        %Macro.Env{} = env,
        meta
      ) do
    {mode, pattern, source} = Assertion.parse_binding!(binder, binding_ast, env)
    members = Assertion.parse_scoped_assertions!(binder, scoped, env)

    binding = %{
      mode: mode,
      pattern: pattern,
      source: source,
      group_id: Assertion.generate_group_id()
    }

    for {label, expr} <- members, do: stash_assertion(ctx, kind, expr, label, env, meta, binding)
    :ok
  end

  @doc """
  Validates and stores a single pending assertion under the context's pending attribute for
  `kind`. `binding` tags it as a member of a `where`/`whenever` group (`nil` for an ordinary
  assertion).
  """
  def stash_assertion(
        %Context{} = ctx,
        kind,
        expression,
        label,
        %Macro.Env{} = env,
        meta,
        binding \\ nil
      ) do
    Assertion.validate_expression!(expression, env)

    assertion = Assertion.new(kind, label, expression, env, meta)
    assertion = if binding, do: Assertion.put_binding(assertion, binding), else: assertion

    # `env.module` is the behaviour module itself — the origin of this inherited contract.
    assertion =
      if ctx.stamp_source_behaviour,
        do: %{assertion | source_behaviour: env.module},
        else: assertion

    attr = pending_attr(ctx, kind)

    Module.put_attribute(env.module, attr, [
      assertion | Module.get_attribute(env.module, attr) || []
    ])

    :ok
  end

  @doc """
  Returns the pending assertions of `kind` for `module`, in declaration order.
  """
  def pending(%Context{} = ctx, module, kind) do
    (Module.get_attribute(module, pending_attr(ctx, kind)) || []) |> Enum.reverse()
  end

  @doc """
  Clears both pending (`@pre` and `@post`) accumulators for `module`.
  """
  def clear_pending(%Context{} = ctx, module) do
    Module.put_attribute(module, ctx.pending_pre_key, [])
    Module.put_attribute(module, ctx.pending_post_key, [])
    :ok
  end

  defp pending_attr(%Context{pending_pre_key: key}, :precondition), do: key
  defp pending_attr(%Context{pending_post_key: key}, :postcondition), do: key

  @doc """
  Takes everything pending for the operation now being declared — `@pre`, `@post`, and any
  `@apply_contract` — clearing all three accumulators, and rejects the one combination that is
  not allowed.

  Returns `{pre, post, applied}` (where `applied` is `{ref, apply_env}` or `nil`) when anything
  was pending, or `:none` when nothing was: an uncontracted callback or protocol function
  contributes no entry for implementers to inherit.

  `@apply_contract` and plain `@pre`/`@post` on the same declaration is a compile error. The two
  express the whole contract in different vocabularies — the named contract's canonical argument
  names versus the operation's own — so combining them would silently pick one. The error is
  positioned at the `@apply_contract`, which is the annotation to remove.

  Shared by `Bond.Behaviour` and `Bond.Protocol`; `ctx.declaration_form` names the declaration
  (`@callback` / protocol `def`) in the diagnostic.
  """
  @spec take_pending!(Context.t(), module()) ::
          {[Assertion.t()], [Assertion.t()], {term(), Macro.Env.t()} | nil} | :none
  def take_pending!(%Context{} = ctx, module) do
    pre = pending(ctx, module, :precondition)
    post = pending(ctx, module, :postcondition)
    applied = Module.get_attribute(module, ctx.pending_apply_key)

    clear_pending(ctx, module)
    Module.put_attribute(module, ctx.pending_apply_key, nil)

    if applied != nil and (pre != [] or post != []) do
      {_ref, apply_env} = applied

      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: @apply_contract and @pre/@post cannot both precede the same " <>
            "#{ctx.declaration_form}. Use @apply_contract alone, or @pre/@post alone."
    end

    if applied == nil and pre == [] and post == [], do: :none, else: {pre, post, applied}
  end

  @doc """
  Resolves the taken pending contracts of one operation into the
  `{canonical_arg_names, preconditions, postconditions}` triple that `Bond.Behaviour` and
  `Bond.Protocol` store per `{name, arity}`.

  With no `@apply_contract` the operation's own declared argument names are canonical and its
  `@pre`/`@post` pass through. With one, `Bond.Compiler.NamedContracts.expand_for_callback/6`
  supplies both the contract's clauses and its canonical names (falling back to
  `declared_arg_names` for a zero-argument, result-only contract).

  Either way the result is validated with `validate_referenced_names!/6`, so a contract naming
  something the operation does not bind is caught at the behaviour/protocol's own compile time —
  where the error can point at the offending `@pre`/`@post` — rather than surfacing as an opaque
  "undefined variable" inside generated code in every implementer.
  """
  @spec resolve_contract!(
          Context.t(),
          {atom(), arity()},
          [atom()],
          {[Assertion.t()], [Assertion.t()], {term(), Macro.Env.t()} | nil},
          Macro.Env.t()
        ) :: {[atom()], [Assertion.t()], [Assertion.t()]}
  def resolve_contract!(
        %Context{} = ctx,
        {name, arity} = key,
        declared_arg_names,
        {pre, post, applied},
        %Macro.Env{} = env
      ) do
    {canonical_names, all_pre, all_post} =
      case applied do
        nil ->
          {declared_arg_names, pre, post}

        {ref, apply_env} ->
          Bond.Compiler.NamedContracts.expand_for_callback(
            ref,
            name,
            arity,
            declared_arg_names,
            env,
            apply_env
          )
      end

    validate_referenced_names!(ctx, all_pre, all_post, key, canonical_names, env)

    {canonical_names, all_pre, all_post}
  end

  @doc """
  Raises when `@pre`/`@post`/`@apply_contract` are still pending at the end of a behaviour or
  protocol module — they were written without a declaration following them, so they constrain
  nothing.

  Called from each flavour's `__before_compile__`. Returns `:ok` when nothing is left over.
  """
  @spec assert_nothing_pending!(Context.t(), Macro.Env.t()) :: :ok
  def assert_nothing_pending!(%Context{} = ctx, %Macro.Env{} = env) do
    leftover_pre = pending(ctx, env.module, :precondition)
    leftover_post = pending(ctx, env.module, :postcondition)
    leftover_apply = Module.get_attribute(env.module, ctx.pending_apply_key)

    if leftover_pre != [] or leftover_post != [] or leftover_apply != nil do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: @pre/@post (or @apply_contract) in #{inspect(env.module)} do not precede " <>
            "#{article(ctx.declaration_form)} #{ctx.declaration_form}. Contracts on a " <>
            "#{ctx.contract_subject} must immediately precede the declaration they constrain."
    end

    :ok
  end

  defp article("@" <> _), do: "an"
  defp article(_form), do: "a"

  @doc """
  Verifies every variable a contract references is a name the operation actually binds: one of
  its named arguments, plus `result` in a postcondition.

  Caught here at the behaviour/protocol's own compile time, the error points at the offending
  `@pre`/`@post`; left to the implementer it would surface only as an opaque "undefined variable"
  inside Bond-generated code, far from the cause. When `ctx.reject_old` is set, also rejects
  `old/1` in a postcondition.
  """
  def validate_referenced_names!(%Context{} = ctx, pre, post, {name, arity}, arg_names, env) do
    named = referenceable_names(arg_names)

    validate_assertions!(ctx, pre, named, {name, arity}, arg_names, env, "precondition")

    validate_assertions!(
      ctx,
      post,
      MapSet.put(named, :result),
      {name, arity},
      arg_names,
      env,
      "postcondition"
    )

    if ctx.reject_old do
      reject_old!(pre, {name, arity}, env)
      reject_old!(post, {name, arity}, env)
    end

    :ok
  end

  defp validate_assertions!(
         %Context{} = ctx,
         assertions,
         allowed,
         {name, arity},
         arg_names,
         env,
         kind
       ) do
    for %Assertion{} = assertion <- assertions do
      unknown =
        assertion
        |> referenced_names()
        |> MapSet.difference(allowed)
        |> Enum.sort()

      if unknown != [] do
        raise CompileError,
          file: env.file,
          line: assertion.definition_env.line || env.line,
          description: unknown_reference_message(ctx, unknown, {name, arity}, arg_names, kind)
      end
    end
  end

  # The argument/`result` names an assertion references. For a `where`/`whenever` group member
  # (#47) the expression is evaluated inside the binding's `case`, so the pattern-bound names are
  # *not* references (subtract them — they shadow nothing here, they're locally bound) while the
  # binding source *is* evaluated in the operation's scope (add its references). Mirrors
  # `Bond.Compiler.Clauses.referenced_param_names/2`'s binding-awareness.
  defp referenced_names(%Assertion{binding: nil, expression: expression}),
    do: Clauses.expression_var_names(expression)

  defp referenced_names(%Assertion{
         binding: %{pattern: pattern, source: source},
         expression: expression
       }) do
    member_refs =
      MapSet.difference(
        Clauses.expression_var_names(expression),
        Clauses.pattern_binding_names(pattern)
      )

    MapSet.union(member_refs, Clauses.expression_var_names(source))
  end

  # Only genuinely named positions are referenceable; unnamed positions get a generated
  # `bond_arg_<idx>` placeholder that no contract can meaningfully name.
  @doc false
  def referenceable_names(arg_names) do
    arg_names
    |> Enum.reject(&generated_name?/1)
    |> MapSet.new()
  end

  @doc false
  def generated_name?(name), do: String.starts_with?(Atom.to_string(name), "bond_arg_")

  @doc false
  def unknown_reference_message(%Context{} = ctx, unknown, {name, arity}, arg_names, kind) do
    referenceable = Enum.reject(arg_names, &generated_name?/1)

    names_phrase =
      case referenceable do
        [] -> "the #{ctx.noun} declares no named arguments"
        names -> "the #{ctx.noun}'s argument names are #{Enum.map_join(names, ", ", &"`#{&1}`")}"
      end

    extra = if kind == "postcondition", do: " (and `result` for the return value)", else: ""

    hint =
      if ctx.arg_naming_hint? do
        " Name the callback's arguments (e.g. " <>
          "`@callback #{name}(amount :: integer, …) :: …`) so contracts can bind to them positionally."
      else
        ""
      end

    "Bond: the #{kind} on `#{name}/#{arity}` references " <>
      "#{Enum.map_join(unknown, ", ", &"`#{&1}`")}, which #{verb(unknown)} not a #{ctx.noun} " <>
      "argument. A contract on a #{ctx.contract_subject} may reference only #{ctx.reference_scope}" <>
      "#{extra}; #{names_phrase}.#{hint}"
  end

  @doc false
  def verb([_single]), do: "is"
  def verb(_many), do: "are"

  # `old/1` captures a value at function entry for use in a postcondition. The protocol dispatch
  # wrapper does not snapshot entry state (a v1 non-goal), so reject `old(...)` with a clear error
  # rather than letting it surface as an "undefined function old/1" deep in generated code.
  # Called for both pre and post so @pre_weaken old(...) is also caught with a clear message.
  @doc false
  def reject_old!(assertions, {name, arity}, env) do
    for %Assertion{expression: expression, kind: kind} = assertion <- assertions do
      if uses_old?(expression) do
        kind_str = if kind == :postcondition, do: "postcondition", else: "precondition"

        raise CompileError,
          file: env.file,
          line: assertion.definition_env.line || env.line,
          description:
            "Bond: the #{kind_str} on `#{name}/#{arity}` uses `old/1`, which is not supported " <>
              "in protocol contracts (v1)."
      end
    end

    :ok
  end

  @doc false
  # Whether an assertion expression contains an `old(...)` capture, anywhere. Shared with
  # `Bond.Compiler`, which rejects `old/1` in a `@post_strengthen` for the same reason this
  # module rejects it in a protocol contract: it is not precompiled on those paths, so left
  # alone it would surface as "undefined function old/1" deep inside generated code.
  @spec uses_old?(Macro.t()) :: boolean()
  def uses_old?(expression) do
    {_, found?} =
      Macro.prewalk(expression, false, fn
        {:old, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end
