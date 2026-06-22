defmodule Bond.Compiler.NamedContracts do
  @moduledoc internal: true
  @moduledoc """
  Compile-time capture and storage for reusable *named contracts* (`defcontract`).

  A `defcontract name(arg1, arg2) do @pre … ; @post … end` declares a reusable bundle of
  pre/postconditions, identified by `{name, arity}`, that other functions apply with
  `@apply_contract`. The head's parameter list supplies the contract's **canonical argument
  names** (and their order) — exactly the role a `@callback`'s signature plays for
  `Bond.Behaviour`. A named contract is, structurally, an inherited contract whose source is a
  local/remote definition rather than a behaviour callback, so it reuses the same downstream
  machinery: `Bond.Compiler.InheritedContracts.validate_referenced_names!/6` for reference
  checking and, at application time, the positional rebind via
  `Bond.Compiler.AnnotatedFunction`'s `canonical_names_override`.

  `defcontract` receives its body as raw, unexpanded AST, so it parses the `@pre`/`@post` nodes
  itself rather than relying on (or fighting) the `Kernel.@/1` override `use Bond` installs.
  That keeps capture decoupled from `at_annotations:` and from the FSM that accumulates
  function-level contracts.

  Captured contracts are stashed in the `#{inspect(:__bond_named_contracts__)}` module attribute
  as a list of `{{name, arity}, entry}` pairs in reverse declaration order, where `entry` is
  `%{arg_names: [atom], preconditions: [Assertion.t], postconditions: [Assertion.t]}` — the same
  shape `Bond.Behaviour` stores per callback. The reflection function and application-time
  resolution read it back through `registry/1`.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Clauses
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context

  @registry_attr :__bond_named_contracts__

  @doc """
  The module attribute under which captured named contracts are accumulated.
  """
  def registry_attr, do: @registry_attr

  @doc """
  Captures a `defcontract` definition into the defining module's named-contract registry.

  `head` is the call AST (`name(arg1, arg2)`), `block` the body AST. Parses the head into
  `{name, arity, arg_names}`, collects the body's `@pre`/`@post` into `Assertion` structs,
  validates that every referenced name is a declared argument (plus `result` in a `@post`), and
  stores the entry keyed by `{name, arity}`. Performs its work via `Module.put_attribute/3` at
  expansion time and returns `:ok` (the `defcontract` macro emits no runtime code).
  """
  @spec define(Macro.t(), Macro.t(), Macro.Env.t()) :: :ok
  def define(head, block, %Macro.Env{} = env) do
    {name, arity, arg_names} = parse_head(head, env)
    {pre, post, includes} = capture_body(block, env)

    if pre == [] and post == [] and includes == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: defcontract #{name}/#{arity} declares nothing. A named contract must declare " <>
            "at least one @pre, @post, or include."
    end

    InheritedContracts.validate_referenced_names!(ctx(), pre, post, {name, arity}, arg_names, env)
    validate_include_args!(includes, name, arg_names, env)

    register(
      env.module,
      {name, arity},
      %{
        arg_names: arg_names,
        preconditions: pre,
        postconditions: post,
        includes: includes
      },
      env
    )

    :ok
  end

  @doc """
  Returns the module's captured named contracts as a list of `{{name, arity}, entry}` pairs in
  declaration order. Reads the raw module attribute, so it is only meaningful while `module` is
  still compiling.
  """
  @spec registry(module()) :: [{{atom(), arity()}, map()}]
  def registry(module) do
    (Module.get_attribute(module, @registry_attr) || []) |> Enum.reverse()
  end

  # --- head parsing ---

  # `name(arg1, arg2, …)` — the canonical case. Each argument must be a bare variable; patterns,
  # guards, and default values are rejected so the head reads as a clean canonical signature.
  defp parse_head({name, _meta, args}, env) when is_atom(name) and is_list(args) do
    {name, length(args), Enum.map(args, &parse_arg(&1, name, env))}
  end

  # `defcontract name do … end` (no parens) parses the head as a bare variable — args is the
  # context atom, not a list. Point the user at the parameter-list form.
  defp parse_head({name, _meta, ctx}, env) when is_atom(name) and is_atom(ctx) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: defcontract #{name} needs a parameter list, e.g. " <>
          "`defcontract #{name}(account, amount) do … end` " <>
          "(use `#{name}()` for a zero-argument contract)."
  end

  defp parse_head(other, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: malformed defcontract head `#{Macro.to_string(other)}`. Expected " <>
          "`defcontract name(arg1, arg2, …) do … end`."
  end

  defp parse_arg({arg, _meta, ctx}, _name, _env) when is_atom(arg) and is_atom(ctx), do: arg

  defp parse_arg(other, name, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: defcontract #{name} parameter `#{Macro.to_string(other)}` is not a simple " <>
          "variable. Contract parameters must be bare names (e.g. `account`, `amount`); " <>
          "patterns, guards, and default values are not allowed."
  end

  # --- body capture ---

  defp capture_body(block, env) do
    block
    |> block_statements()
    |> Enum.reduce({[], [], []}, fn statement, {pre, post, includes} ->
      case classify_statement(statement, env) do
        {:precondition, assertions} -> {pre ++ assertions, post, includes}
        {:postcondition, assertions} -> {pre, post ++ assertions, includes}
        {:include, directive} -> {pre, post, includes ++ [directive]}
      end
    end)
  end

  defp block_statements({:__block__, _meta, statements}), do: statements
  defp block_statements(nil), do: []
  defp block_statements(single), do: [single]

  # A single labelled-or-bare `@pre`/`@post`, mirroring the `use Bond` surface.
  defp classify_statement({:@, _meta, [{kind, kmeta, [expression]}]}, env)
       when kind in [:pre, :post] do
    assertion_kind = if kind == :pre, do: :precondition, else: :postcondition
    {assertion_kind, build_assertions(assertion_kind, expression, env, kmeta)}
  end

  # `include name(args)` / `include Module.name(args)` — compose another contract's clauses into
  # this one (#40). Captured raw here; resolved, substituted, and flattened at __before_compile__.
  defp classify_statement({:include, _meta, [call]}, env) do
    {:include, parse_include(call, env)}
  end

  # `@pre`/`@post` with 2+ args — the bare-mixed-with-labelled trip, same as the `use Bond`
  # catch-all. Diagnose it here rather than treating it as a non-contract statement.
  defp classify_statement({:@, _meta, [{kind, kmeta, [_, _ | _]}]}, env)
       when kind in [:pre, :post] do
    raise CompileError,
      file: env.file,
      line: Keyword.get(kmeta, :line, env.line),
      description:
        "@#{kind} accepts a single argument — either a bare assertion expression or a keyword " <>
          "list of `label: assertion` pairs (e.g. `@#{kind} positive: amount > 0`). Use a " <>
          "separate @#{kind} line per bare assertion."
  end

  defp classify_statement(other, env) do
    raise CompileError,
      file: env.file,
      line: statement_line(other, env),
      description:
        "Bond: a defcontract body may contain only @pre and @post declarations. Found: " <>
          "`#{Macro.to_string(other)}`."
  end

  # Build one assertion per `label: expr` pair (keyword-list form) or a single unlabelled
  # assertion (bare form) — identical labelling to `InheritedContracts.accumulate_pending/5`.
  defp build_assertions(kind, expression, env, meta) do
    if Keyword.keyword?(expression) do
      for {label, expr} <- expression do
        Assertion.validate_expression!(expr, env)
        Assertion.new(kind, label, expr, env, meta)
      end
    else
      Assertion.validate_expression!(expression, env)
      [Assertion.new(kind, nil, expression, env, meta)]
    end
  end

  defp statement_line({_, meta, _}, env) when is_list(meta),
    do: Keyword.get(meta, :line, env.line)

  defp statement_line(_other, env), do: env.line

  # --- include parsing ---

  # Local: `include name(arg, …)`. The included contract is identified by `{name, arity}` where
  # arity is the number of arguments passed; the args are arbitrary expressions over THIS contract's
  # parameters, substituted into the included contract's clauses at flatten time (#40).
  defp parse_include({name, _meta, args}, env) when is_atom(name) and is_list(args) do
    %{ref: {:local, name, length(args)}, name: name, args: args, env: env}
  end

  # Remote: `include Module.name(arg, …)`. The module alias is expanded in the caller's context now,
  # establishing the compile-time dependency for the cross-module read at flatten time.
  defp parse_include({{:., _, [module_ast, name]}, _meta, args}, env)
       when is_atom(name) and is_list(args) do
    module = Macro.expand(module_ast, env)
    %{ref: {:remote, module, name, length(args)}, name: name, args: args, env: env}
  end

  defp parse_include(other, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description:
        "Bond: `include` expects a contract call — `include name(arg, …)` or " <>
          "`include Module.name(arg, …)`. Got: `#{Macro.to_string(other)}`."
  end

  # Each `include` argument is substituted into the included contract's assertions, so it must
  # reference only THIS contract's declared arguments (the names in scope when the host is applied).
  defp validate_include_args!(includes, host_name, host_arg_names, env) do
    allowed = MapSet.new(host_arg_names)

    for %{args: args, env: include_env} <- includes, arg <- args do
      unknown =
        arg
        |> Clauses.expression_var_names()
        |> MapSet.difference(allowed)
        |> Enum.sort()

      if unknown != [] do
        raise CompileError,
          file: include_env.file,
          line: include_env.line,
          description:
            "Bond: include argument `#{Macro.to_string(arg)}` references " <>
              "#{Enum.map_join(unknown, ", ", &"`#{&1}`")}, which #{verb(unknown)} not an " <>
              "argument of contract #{host_name}. Include arguments may reference only its " <>
              "arguments: #{Enum.map_join(host_arg_names, ", ", &"`#{&1}`")}."
      end
    end

    :ok
  end

  defp verb([_single]), do: "is"
  defp verb(_many), do: "are"

  # --- registry ---

  defp register(module, {name, arity} = key, entry, env) do
    current = Module.get_attribute(module, @registry_attr) || []

    if List.keymember?(current, key, 0) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: defcontract #{name}/#{arity} is already defined in #{inspect(module)}."
    end

    Module.put_attribute(module, @registry_attr, [{key, entry} | current])
  end

  # Reference-validation context for the named-contract flavour. `validate_referenced_names!/6`
  # uses only the diagnostic-wording fields and `reject_old`; the pending-key fields are required
  # by the struct but unused here (capture does not go through the pending accumulators).
  defp ctx do
    %Context{
      noun: "contract",
      contract_subject: "named contract",
      reference_scope: "its declared arguments",
      pending_pre_key: :__bond_named_contract_pending_pre__,
      pending_post_key: :__bond_named_contract_pending_post__,
      reject_old: false,
      arg_naming_hint?: false
    }
  end
end
