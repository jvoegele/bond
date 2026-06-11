defmodule Bond.Protocol do
  @moduledoc """
  Declare `@pre`/`@post` contracts on a `defprotocol`'s functions and have them enforced across
  every implementation — present or future — at the dispatch boundary.

  Like `Bond.Behaviour`, this is Design by Contract meeting the Liskov Substitution Principle: a
  protocol is a promise about a *family* of implementations, and a contract is the formal content
  of that promise. Unlike behaviour inheritance, nothing is required of the implementations — a
  `defimpl` stays completely ordinary and needs no Bond awareness.

      defprotocol Sized do
        use Bond.Protocol

        @post non_negative: result >= 0
        @spec size(t) :: non_neg_integer()
        def size(data)
      end

      defimpl Sized, for: List do
        def size(list), do: length(list)
      end

  A `@pre`/`@post` precedes the `def` it attaches to, exactly as a contract precedes the `def`
  it attaches to in `use Bond`. The contract expressions reference the protocol function's
  declared argument names (`data` above) and, in a `@post`, `result` (the return value).

  ## How it works (Option B — dispatch-layer wrapping)

  `defprotocol` generates a *dispatch* function — `Sized.size(data)` calls
  `Sized.impl_for!(data).size(data)`. `Bond.Protocol` wraps that one dispatch function, once, in
  the protocol module: at `@before_compile` it marks the function `defoverridable` and redefines
  it to evaluate the precondition, call `super/…` (the original dispatch), then evaluate the
  postcondition. Because the wrap is on dispatch, it applies uniformly to every implementation,
  and it survives protocol consolidation.

  ## Diagnostics

  A violation is attributed to the protocol and names the implementation the call resolved to:
  the message reads `postcondition (from protocol Sized, impl Sized.List) failed in
  Sized.size/1`, with `:source_protocol` and `:impl` on the error struct and the
  `[:bond, :assertion, :failure]` telemetry metadata.

  ## Scope (v1)

  Inherited contracts are immutable: implementations enforce the protocol's contracts verbatim
  and cannot refine them (that is the refinement feature's job). Direct calls to a concrete
  implementation module (`Sized.List.size/1`) bypass dispatch and are therefore *not* checked —
  only calls through the protocol (`Sized.size/1`) are. `old/1` in a protocol `@post` and
  compile-time `:purge` of protocol contracts are not supported in v1; runtime configuration
  (`config :bond, …` and `Bond.Config`) applies as usual.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Clauses

  # Storage-attribute keys are inline atom literals returned by these helpers, NOT `@name value`
  # module-attribute constants: a module that defines a local `@/1` macro can't also use
  # `@name value` to set a custom attribute (the call is ambiguous with the shadowed
  # `Kernel.@/1`). The reserved `@moduledoc`/`@doc`/`@before_compile` forms are unaffected.
  defp pending_pre_key, do: :__bond_protocol_pending_pre__
  defp pending_post_key, do: :__bond_protocol_pending_post__
  defp contracts_key, do: :__bond_protocol_contracts__

  @doc false
  defmacro __using__(_opts) do
    quote do
      # Shadow `@` to intercept `@pre`/`@post`, and `def` to capture each protocol function's
      # name/arity/argument names. `defprotocol` has already done
      # `import Kernel, except: [def: 1, def: 2]` + `import Protocol, only: [def: 1]`, so we
      # first drop `Protocol.def` from scope (re-importing it with `except`) and then shadow it
      # with ours; `Bond.Protocol.def/1` forwards to `Protocol.def/1` after capturing.
      import Kernel, except: [@: 1]
      import Protocol, except: [def: 1]
      import Bond.Protocol, only: [@: 1, def: 1]

      @before_compile Bond.Protocol
    end
  end

  # --- @pre/@post capture (everything else passes through to Kernel.@/1) ---

  @doc false
  defmacro @pre_post_or_other

  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    kind = if pre_or_post == :pre, do: :precondition, else: :postcondition
    accumulate_pending(kind, expression, __CALLER__, meta)
    :ok
  end

  defmacro @other do
    quote do
      Kernel.@(unquote(other))
    end
  end

  # --- def capture: record contracts against {name, arity}, then forward to Protocol.def ---

  @doc false
  defmacro def({name, _meta, args} = head) when is_atom(name) and is_list(args) do
    register_function_contracts(name, args, __CALLER__)

    quote do
      Protocol.def(unquote(head))
    end
  end

  # `def name` with no argument list (arity 0) — protocols require at least one argument to
  # dispatch on, but forward it so `Protocol.def` raises its own diagnostic rather than ours.
  defmacro def(head) do
    quote do
      Protocol.def(unquote(head))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    leftover_pre = pending(env.module, pending_pre_key())
    leftover_post = pending(env.module, pending_post_key())

    if leftover_pre != [] or leftover_post != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: @pre/@post in #{inspect(env.module)} do not precede a protocol `def`. " <>
            "Contracts on a protocol must immediately precede the function they constrain."
    end

    contracts = Module.get_attribute(env.module, contracts_key()) || []

    wrappers =
      for {{name, arity}, arg_names, pre, post} <- Enum.reverse(contracts) do
        build_wrapper(env.module, name, arity, arg_names, pre, post)
      end

    {:__block__, [], wrappers}
  end

  # --- internal: pending accumulation (mirrors Bond.Behaviour) ---

  defp accumulate_pending(kind, expression, %Macro.Env{} = env, meta) do
    if Keyword.keyword?(expression) do
      for {label, expr} <- expression, do: stash_assertion(kind, expr, label, env, meta)
    else
      stash_assertion(kind, expression, nil, env, meta)
    end
  end

  defp stash_assertion(kind, expression, label, env, meta) do
    Assertion.validate_expression!(expression, env)
    assertion = Assertion.new(kind, label, expression, env, meta)
    attr = pending_attr(kind)

    Module.put_attribute(env.module, attr, [
      assertion | Module.get_attribute(env.module, attr) || []
    ])
  end

  defp pending_attr(:precondition), do: pending_pre_key()
  defp pending_attr(:postcondition), do: pending_post_key()

  defp pending(module, attr), do: (Module.get_attribute(module, attr) || []) |> Enum.reverse()

  # --- internal: record a function's contracts ---

  defp register_function_contracts(name, args, %Macro.Env{} = env) do
    pre = pending(env.module, pending_pre_key())
    post = pending(env.module, pending_post_key())

    Module.put_attribute(env.module, pending_pre_key(), [])
    Module.put_attribute(env.module, pending_post_key(), [])

    if pre != [] or post != [] do
      arg_names = canonical_arg_names(args)
      validate_referenced_names!(pre, post, {name, length(args)}, arg_names, env)

      entry = {{name, length(args)}, arg_names, pre, post}
      contracts = Module.get_attribute(env.module, contracts_key()) || []
      Module.put_attribute(env.module, contracts_key(), [entry | contracts])
    end
  end

  defp canonical_arg_names(args) do
    args
    |> Enum.with_index()
    |> Enum.map(fn
      {{n, _, ctx}, _idx} when is_atom(n) and is_atom(ctx) -> n
      {_arg, idx} -> :"bond_arg_#{idx}"
    end)
  end

  # --- internal: reference validation (mirrors Bond.Behaviour) ---

  defp validate_referenced_names!(pre, post, {name, arity}, arg_names, env) do
    named = referenceable_names(arg_names)
    validate_assertions!(pre, named, {name, arity}, arg_names, env, "precondition")

    validate_assertions!(
      post,
      MapSet.put(named, :result),
      {name, arity},
      arg_names,
      env,
      "postcondition"
    )

    reject_old!(post, {name, arity}, env)
  end

  # `old/1` captures a value at function entry for use in a postcondition. The dispatch wrapper
  # does not snapshot entry state (a v1 non-goal), so reject `old(...)` with a clear error rather
  # than letting it surface as an "undefined function old/1" deep in generated code.
  defp reject_old!(post, {name, arity}, env) do
    for %Assertion{expression: expression} = assertion <- post do
      if uses_old?(expression) do
        raise CompileError,
          file: env.file,
          line: assertion.definition_env.line || env.line,
          description:
            "Bond: the postcondition on `#{name}/#{arity}` uses `old/1`, which is not supported " <>
              "in protocol contracts (v1). A protocol `@post` may reference only the function's " <>
              "arguments and `result`."
      end
    end
  end

  defp uses_old?(expression) do
    {_, found?} =
      Macro.prewalk(expression, false, fn
        {:old, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp validate_assertions!(assertions, allowed, {name, arity}, arg_names, env, kind) do
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
          description: unknown_reference_message(unknown, {name, arity}, arg_names, kind)
      end
    end
  end

  defp referenceable_names(arg_names) do
    arg_names |> Enum.reject(&generated_name?/1) |> MapSet.new()
  end

  defp generated_name?(name), do: String.starts_with?(Atom.to_string(name), "bond_arg_")

  defp unknown_reference_message(unknown, {name, arity}, arg_names, kind) do
    referenceable = Enum.reject(arg_names, &generated_name?/1)

    names_phrase =
      case referenceable do
        [] -> "the function declares no named arguments"
        names -> "the function's argument names are #{Enum.map_join(names, ", ", &"`#{&1}`")}"
      end

    extra = if kind == "postcondition", do: " (and `result` for the return value)", else: ""

    "Bond: the #{kind} on `#{name}/#{arity}` references " <>
      "#{Enum.map_join(unknown, ", ", &"`#{&1}`")}, which #{verb(unknown)} not a function " <>
      "argument. A contract on a protocol function may reference only its named arguments" <>
      "#{extra}; #{names_phrase}."
  end

  defp verb([_single]), do: "is"
  defp verb(_many), do: "are"

  # --- internal: wrapper + lifted-defp emission ---
  #
  # All generated code uses fully-qualified `Kernel.def`/`Kernel.defp`/`Kernel.defoverridable`
  # because the protocol body excludes `Kernel.def`. The lifted assertion bodies reuse
  # `Assertion.assertions_body/3` (so the conditional-compilation chain, error structs, and
  # stacktrace pruning are shared with ordinary contracts), and the runtime gate uses a
  # compile default of `true` — global config and `Bond.Config` still toggle protocol contracts
  # at runtime via `should_evaluate?/3`.

  defp build_wrapper(protocol, name, arity, arg_names, pre, post) do
    arg_vars = Enum.map(arg_names, &Macro.var(&1, nil))
    result_var = Macro.var(:result, nil)
    subject = List.first(arg_vars)
    function_info = {name, arity}

    pre_fn = :"__bond_protocol_pre_#{name}_#{arity}__"
    post_fn = :"__bond_protocol_post_#{name}_#{arity}__"
    pre_chain = if pre != [], do: true, else: :purge

    wrapper_body =
      if(pre != [], do: [pre_eval_stmt(protocol, subject, pre_fn, arg_vars)], else: []) ++
        [quote(do: unquote(result_var) = super(unquote_splicing(arg_vars)))] ++
        if(post != [],
          do: [post_eval_stmt(protocol, subject, post_fn, arg_vars, pre_chain)],
          else: []
        ) ++
        [result_var]

    statements =
      [
        quote do
          Kernel.defoverridable([{unquote(name), unquote(arity)}])

          Kernel.def unquote(name)(unquote_splicing(arg_vars)) do
            (unquote_splicing(wrapper_body))
          end
        end
      ] ++
        if pre != [] do
          [
            quote do
              Kernel.defp unquote(pre_fn)(unquote_splicing(arg_vars)) do
                unquote(Assertion.assertions_body(pre, function_info))
              end
            end
          ]
        else
          []
        end ++
        if post != [] do
          [
            quote do
              Kernel.defp unquote(post_fn)(unquote_splicing(arg_vars), unquote(result_var)) do
                unquote(Assertion.assertions_body(post, function_info))
              end
            end
          ]
        else
          []
        end

    {:__block__, [], statements}
  end

  defp pre_eval_stmt(protocol, subject, pre_fn, arg_vars) do
    quote do
      if Bond.Runtime.Eval.should_evaluate?(:preconditions, true) do
        Bond.Runtime.Eval.evaluate_protocol_assertions(unquote(protocol), unquote(subject), fn ->
          unquote(pre_fn)(unquote_splicing(arg_vars))
        end)
      end
    end
  end

  defp post_eval_stmt(protocol, subject, post_fn, arg_vars, pre_chain) do
    result_var = Macro.var(:result, nil)
    chain = Macro.escape(%{preconditions: pre_chain})

    quote do
      if Bond.Runtime.Eval.should_evaluate?(:postconditions, true, unquote(chain)) do
        Bond.Runtime.Eval.evaluate_protocol_assertions(unquote(protocol), unquote(subject), fn ->
          unquote(post_fn)(unquote_splicing(arg_vars), unquote(result_var))
        end)
      end
    end
  end
end
