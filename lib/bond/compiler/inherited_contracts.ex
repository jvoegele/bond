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
  Validates and stores a single pending assertion under the context's pending attribute for
  `kind`.
  """
  def stash_assertion(%Context{} = ctx, kind, expression, label, %Macro.Env{} = env, meta) do
    Assertion.validate_expression!(expression, env)

    assertion = Assertion.new(kind, label, expression, env, meta)

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
    for %Assertion{expression: expression} = assertion <- assertions do
      unknown =
        expression
        |> Clauses.expression_var_names()
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

  defp uses_old?(expression) do
    {_, found?} =
      Macro.prewalk(expression, false, fn
        {:old, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end
