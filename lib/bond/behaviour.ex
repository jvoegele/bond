defmodule Bond.Behaviour do
  @moduledoc """
  Declare `@pre`/`@post` contracts on a behaviour's `@callback`s and have them enforced on
  every implementing module.

  This is where Design by Contract meets the Liskov Substitution Principle: a behaviour is a
  promise about a *family* of implementations, and a contract is the formal content of that
  promise. A module that `use Bond.Behaviour` attaches contracts to its callbacks; a module
  that `use Bond, behaviours: [TheBehaviour]` inherits and enforces those contracts on its
  own clauses.

      defmodule Ledger do
        use Bond.Behaviour

        @pre positive_amount: amount > 0
        @post non_negative: result >= 0
        @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
      end

      defmodule BankAccount do
        use Bond, behaviours: [Ledger]

        @impl true
        def withdraw(balance, amount) when amount <= balance, do: balance - amount
      end

  A `@pre`/`@post` precedes the `@callback` it attaches to, exactly as a contract precedes the
  `def` it attaches to in `use Bond`. The contract expressions reference the **callback's
  argument names** (`balance`, `amount` above); those names become canonical, and an
  implementation's parameters are rebound to them positionally — so the impl is free to name
  its parameters differently.

  ## Immutable inheritance (v1)

  Inherited contracts are **immutable**: an implementation may not weaken, strengthen, or add
  to them. Attaching `@pre`/`@post` to an impl function whose `{name, arity}` matches an
  inherited contract is a compile error — use `Bond.check/1` in the body for
  implementation-specific assertions. Forbidding (rather than silently accepting) impl-level
  contracts on inherited operations keeps that syntax reserved for a future Eiffel-style
  refinement feature (`@pre_else`/`@post_then`).

  ## Reflection

  `use Bond.Behaviour` generates a `__bond_contracts__/0` function on the behaviour module that
  returns its callback contracts keyed by `{name, arity}`. It is an internal reflection hook
  read by `use Bond, behaviours: […]` at the implementer's compile time; you should not call
  it directly.
  """

  alias Bond.Compiler.Assertion
  alias Bond.Compiler.Clauses

  @doc false
  defmacro __using__(_opts) do
    quote do
      # Shadow `Kernel.@/1` so Bond can intercept `@pre`/`@post`/`@callback`. Lexically scoped
      # to this module, exactly as `use Bond` scopes its own `@` override.
      import Kernel, except: [@: 1]
      import Bond.Behaviour, only: [@: 1]

      @before_compile Bond.Behaviour
    end
  end

  @doc """
  Override `Kernel.@/1` so that `@pre`/`@post` can be attached to the following `@callback`.

  Everything other than `@pre`/`@post`/`@callback` is forwarded to `Kernel.@/1` unchanged.
  """
  defmacro @pre_post_callback_or_other

  # `@pre`/`@post`: accumulate as pending contracts for the next `@callback`. Supports the bare
  # form (`@pre amount > 0`) and the keyword-list form (`@pre positive: amount > 0`), mirroring
  # the `use Bond` syntax. Expands to `:ok` — the contract is stashed in a module attribute at
  # expansion time, it produces no runtime code here.
  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    kind = if pre_or_post == :pre, do: :precondition, else: :postcondition
    accumulate_pending(kind, expression, __CALLER__, meta)
    :ok
  end

  # `@callback`: snapshot the pending `@pre`/`@post` and record them against this callback's
  # `{name, arity}`, then forward the spec to `Kernel.@/1` so the callback is registered as
  # usual (the module remains an ordinary behaviour).
  defmacro @{:callback, meta, [spec]} do
    register_callback_contracts(spec, __CALLER__)

    quote do
      Kernel.@(unquote({:callback, meta, [spec]}))
    end
  end

  # Anything else (`@moduledoc`, `@type`, `@spec`, `@macrocallback`, `@optional_callbacks`, …)
  # passes straight through to `Kernel.@/1`.
  defmacro @other do
    quote do
      Kernel.@(unquote(other))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    leftover_pre = pending(env.module, :precondition)
    leftover_post = pending(env.module, :postcondition)

    if leftover_pre != [] or leftover_post != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: @pre/@post in #{inspect(env.module)} do not precede an @callback. " <>
            "Contracts on a behaviour must immediately precede the @callback they constrain."
    end

    contracts = collect_contracts(env.module)

    quote do
      @doc false
      def __bond_contracts__, do: unquote(Macro.escape(contracts))
    end
  end

  # --- internal: pending-contract accumulation ---

  defp accumulate_pending(kind, expression, %Macro.Env{} = env, meta) do
    if Keyword.keyword?(expression) do
      for {label, expr} <- expression do
        stash_assertion(kind, expr, label, env, meta)
      end
    else
      stash_assertion(kind, expression, nil, env, meta)
    end
  end

  defp stash_assertion(kind, expression, label, env, meta) do
    Assertion.validate_expression!(expression, env)
    # `env.module` is the behaviour module itself — the origin of this inherited contract.
    assertion = %{
      Assertion.new(kind, label, expression, env, meta)
      | source_behaviour: env.module
    }

    attr = pending_attr(kind)
    current = Module.get_attribute(env.module, attr) || []
    Module.put_attribute(env.module, attr, [assertion | current])
  end

  # --- internal: callback parsing + contract registration ---

  defp register_callback_contracts(spec, %Macro.Env{} = env) do
    pre = pending(env.module, :precondition)
    post = pending(env.module, :postcondition)

    clear_pending(env.module)

    # Only record an entry when this callback actually carries contracts — uncontracted
    # callbacks contribute nothing for implementers to inherit.
    if pre != [] or post != [] do
      case parse_callback(spec) do
        {name, arity, arg_names} ->
          validate_referenced_names!(pre, post, {name, arity}, arg_names, env)

          entry =
            {{name, arity}, %{arg_names: arg_names, preconditions: pre, postconditions: post}}

          current = Module.get_attribute(env.module, :__bond_callback_contracts__) || []
          Module.put_attribute(env.module, :__bond_callback_contracts__, [entry | current])

        :error ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Bond: could not parse the @callback that the preceding @pre/@post attach to. " <>
                "Bond contracts require a named callback of the form " <>
                "`@callback name(arg :: type, …) :: return`."
      end
    end
  end

  # --- internal: reference validation ---

  # Verify every variable a contract references is a name the callback actually binds: one of
  # its named arguments, plus `result` in a postcondition. Caught here at the behaviour's own
  # compile time, the error points at the offending `@pre`/`@post`; left to the implementer it
  # would surface only as an opaque "undefined variable" inside Bond-generated code, far from
  # the cause (issue #13, open question 2).
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

  # Only genuinely named positions are referenceable; unnamed positions get a generated
  # `bond_arg_<idx>` placeholder that no contract can meaningfully name.
  defp referenceable_names(arg_names) do
    arg_names
    |> Enum.reject(&generated_name?/1)
    |> MapSet.new()
  end

  defp generated_name?(name), do: String.starts_with?(Atom.to_string(name), "bond_arg_")

  defp unknown_reference_message(unknown, {name, arity}, arg_names, kind) do
    referenceable = arg_names |> Enum.reject(&generated_name?/1)

    names_phrase =
      case referenceable do
        [] -> "the callback declares no named arguments"
        names -> "the callback's argument names are #{Enum.map_join(names, ", ", &"`#{&1}`")}"
      end

    extra = if kind == "postcondition", do: " (and `result` for the return value)", else: ""

    "Bond: the #{kind} on `#{name}/#{arity}` references " <>
      "#{Enum.map_join(unknown, ", ", &"`#{&1}`")}, which #{unknown_verb(unknown)} not a callback " <>
      "argument. A contract on a behaviour callback may reference only the callback's named " <>
      "arguments#{extra}; #{names_phrase}. Name the callback's arguments (e.g. " <>
      "`@callback #{name}(amount :: integer, …) :: …`) so contracts can bind to them positionally."
  end

  defp unknown_verb([_single]), do: "is"
  defp unknown_verb(_many), do: "are"

  # Callback spec AST shapes:
  #   name(a :: t, b :: t) :: ret
  #   name(a :: t) :: ret when a: type        (the `when` guard wrapper)
  # Returns `{name, arity, arg_names}` where `arg_names` is one canonical name per position
  # (the callback's argument name, or a generated `bond_arg_<idx>` for an unnamed position).
  defp parse_callback({:when, _meta, [inner | _guards]}), do: parse_callback(inner)

  defp parse_callback({:"::", _meta, [{name, _, args}, _return]})
       when is_atom(name) and is_list(args) do
    {name, length(args), canonical_arg_names(args)}
  end

  defp parse_callback(_), do: :error

  defp canonical_arg_names(args) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, idx} -> arg_name(arg, idx) end)
  end

  # `arg :: type` binds the canonical name `arg`. An unnamed positional type contributes no
  # name; generate one matching `Bond.Compiler.Clauses`' convention so the position is still
  # addressable by the positional rebind (contracts simply can't reference it by name).
  defp arg_name({:"::", _meta, [{name, _, ctx}, _type]}, _idx)
       when is_atom(name) and is_atom(ctx),
       do: name

  defp arg_name(_arg, idx), do: :"bond_arg_#{idx}"

  # --- internal: attribute helpers ---

  defp pending_attr(:precondition), do: :__bond_pending_pre__
  defp pending_attr(:postcondition), do: :__bond_pending_post__

  # Pending lists are accumulated newest-first; return them in declaration order.
  defp pending(module, kind) do
    (Module.get_attribute(module, pending_attr(kind)) || []) |> Enum.reverse()
  end

  defp clear_pending(module) do
    Module.put_attribute(module, :__bond_pending_pre__, [])
    Module.put_attribute(module, :__bond_pending_post__, [])
  end

  defp collect_contracts(module) do
    (Module.get_attribute(module, :__bond_callback_contracts__) || [])
    |> Enum.reverse()
    |> Map.new(fn {key, entry} -> {key, sanitize_entry(entry)} end)
  end

  # The contracts map is emitted into `__bond_contracts__/0` via `Macro.escape/1`. A live
  # `Macro.Env` captured at the `@pre` site cannot be escaped — its `:lexical_tracker` is a
  # pid, which has no quoted form. Reduce each assertion's `definition_env` to a fresh
  # `Macro.Env` holding only the fields the downstream error machinery reads
  # (file/line/module/function); everything else takes its escapable struct default.
  defp sanitize_entry(%{preconditions: pre, postconditions: post} = entry) do
    %{
      entry
      | preconditions: Enum.map(pre, &sanitize_assertion/1),
        postconditions: Enum.map(post, &sanitize_assertion/1)
    }
  end

  defp sanitize_assertion(%Assertion{definition_env: env} = assertion) do
    %{assertion | definition_env: sanitize_env(env)}
  end

  defp sanitize_env(%Macro.Env{} = env) do
    %Macro.Env{file: env.file, line: env.line, module: env.module, function: env.function}
  end
end
