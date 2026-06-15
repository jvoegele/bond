defmodule Bond.Protocol.Impl do
  @moduledoc """
  Opt-in contract refinement for a `defimpl` block.

  `use Bond.Protocol.Impl` inside a `defimpl` lets that implementation *refine* the contracts
  it inherits from the protocol, following Eiffel's behavioural-subtyping rules:

    * `@pre_weaken` **weakens** the inherited precondition — effective pre =
      `inherited OR pre_weaken`. The implementation accepts everything the abstraction promised,
      and *more* (contravariance).
    * `@post_strengthen` **strengthens** the inherited postcondition — effective post =
      `inherited AND post_strengthen`. Callers get at least the abstract guarantee, and *more*
      (covariance).

  Refinement expressions reference the **canonical argument names** declared in the protocol's
  own `def`, not the implementation parameter names (which are often patterns rather than simple
  variables).

  ## Usage

      defprotocol Account do
        use Bond.Protocol

        @pre positive_amount: amount > 0
        @post non_negative: result >= 0
        def withdraw(data, amount)
      end

      defimpl Account, for: SavingsAccount do
        use Bond.Protocol.Impl

        # Accept zero-amount withdrawals too (no-op); canonical name 'amount' from protocol
        @pre_weaken zero_ok: amount == 0
        # Also guarantee the balance changed (or stayed the same on zero withdrawal)
        @post_strengthen unchanged_on_zero: amount == 0 or result < data.balance
        def withdraw(acc, 0), do: acc.balance
        def withdraw(acc, amount), do: acc.balance - amount
      end

  A `@pre_weaken` is only valid when the protocol declares a precondition for that function;
  `@post_strengthen` may add a postcondition even if the protocol declared none. `old/1` is
  not supported in either annotation (protocol contract v1 restriction).

  Implementations that do **not** `use Bond.Protocol.Impl` are completely unaffected.
  """

  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context
  alias Bond.Compiler.ProtocolWrapper

  # Module-attribute keys stored as inline atom literals because the impl module has a shadowed
  # `@/1` macro — using `@name value` syntax inside __using__ would conflict. Same pattern as
  # Bond.Protocol.
  defp pending_pre_key, do: :__bond_impl_pending_pre__
  defp pending_post_key, do: :__bond_impl_pending_post__
  defp refinements_key, do: :__bond_impl_refinements__

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Kernel, except: [@: 1, def: 1, def: 2]
      import Bond.Protocol.Impl, only: [@: 1, def: 1, def: 2]
      @before_compile Bond.Protocol.Impl
    end
  end

  # --- @pre_weaken / @post_strengthen capture (everything else passes to Kernel.@) ---

  @doc false
  defmacro @pre_post_or_other

  defmacro @{refinement, meta, [expression]} when refinement in [:pre_weaken, :post_strengthen] do
    kind = if refinement == :pre_weaken, do: :precondition, else: :postcondition
    InheritedContracts.accumulate_pending(impl_ctx(), kind, expression, __CALLER__, meta)
    :ok
  end

  defmacro @other do
    quote do
      Kernel.@(unquote(other))
    end
  end

  # --- def shadow: associate pending refinements with {name, arity}, then forward to Kernel.def ---

  @doc false
  defmacro def({name, _meta, args} = head, body)
           when is_atom(name) and (is_list(args) or is_nil(args)) do
    arity = length(args || [])

    quote do
      Bond.Protocol.Impl.__consume_pending__(__MODULE__, unquote(name), unquote(arity))
      Kernel.def(unquote(head), unquote(body))
    end
  end

  @doc false
  defmacro def(head) do
    quote do
      Kernel.def(unquote(head))
    end
  end

  @doc false
  def __consume_pending__(module, name, arity) do
    pre = (Module.get_attribute(module, pending_pre_key()) || []) |> Enum.reverse()
    post = (Module.get_attribute(module, pending_post_key()) || []) |> Enum.reverse()

    if pre != [] or post != [] do
      existing = Module.get_attribute(module, refinements_key()) || []
      Module.put_attribute(module, refinements_key(), [{name, arity, pre, post} | existing])
      Module.put_attribute(module, pending_pre_key(), [])
      Module.put_attribute(module, pending_post_key(), [])
    end

    :ok
  end

  @doc false
  defmacro __before_compile__(env) do
    module = env.module
    protocol = Module.get_attribute(module, :protocol)

    # Leftover pending means @pre_weaken / @post_strengthen was not followed by a def.
    leftover_pre = InheritedContracts.pending(impl_ctx(), module, :precondition)
    leftover_post = InheritedContracts.pending(impl_ctx(), module, :postcondition)

    if leftover_pre != [] or leftover_post != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "Bond: @pre_weaken/@post_strengthen in #{inspect(module)} do not precede a `def`. " <>
            "Refinement annotations on a protocol implementation must immediately precede " <>
            "the function clause they refine."
    end

    refinements = (Module.get_attribute(module, refinements_key()) || []) |> Enum.reverse()

    statements =
      Enum.flat_map(refinements, fn {name, arity, pre_weaken, post_strengthen} ->
        build_effective_fns(protocol, module, name, arity, pre_weaken, post_strengthen, env)
      end)

    {:__block__, [], statements}
  end

  # --- internal ---

  defp build_effective_fns(protocol, module, name, arity, pre_weaken, post_strengthen, env) do
    {canonical_arg_names, inherited_pre, inherited_post} =
      fetch_protocol_contract!(protocol, module, name, arity, env)

    if pre_weaken != [] and inherited_pre == [] do
      raise CompileError,
        file: env.file,
        line: (List.first(pre_weaken) || %{definition_env: env}).definition_env.line || env.line,
        description:
          "Bond: @pre_weaken on `#{name}/#{arity}` in #{inspect(module)}: the protocol " <>
            "#{inspect(protocol)} declares no precondition for `#{name}/#{arity}`, so there " <>
            "is nothing to weaken. To add a postcondition where none exists, use " <>
            "@post_strengthen instead."
    end

    InheritedContracts.validate_referenced_names!(
      impl_ctx(),
      pre_weaken,
      post_strengthen,
      {name, arity},
      canonical_arg_names,
      env
    )

    ProtocolWrapper.build_effective_fns(
      name,
      arity,
      canonical_arg_names,
      inherited_pre,
      inherited_post,
      pre_weaken,
      post_strengthen,
      module,
      env
    )
  end

  defp fetch_protocol_contract!(protocol, impl_module, name, arity, env) do
    result =
      try do
        apply(protocol, :__bond_protocol_contract__, [name, arity])
      rescue
        UndefinedFunctionError ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description:
              "Bond: #{inspect(protocol)} does not use Bond.Protocol — " <>
                "@pre_weaken/@post_strengthen in #{inspect(impl_module)} require a " <>
                "Bond.Protocol protocol."
      end

    case result do
      :no_contract ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "Bond: @pre_weaken/@post_strengthen on `#{name}/#{arity}` in " <>
              "#{inspect(impl_module)}: #{inspect(protocol)} declares no Bond contract for " <>
              "`#{name}/#{arity}`. Add @pre/@post to the protocol definition first."

      {arg_names, pre, post} ->
        {arg_names, pre, post}
    end
  end

  defp impl_ctx do
    %Context{
      noun: "function",
      contract_subject: "protocol implementation",
      reference_scope: "the protocol function's named arguments",
      pending_pre_key: pending_pre_key(),
      pending_post_key: pending_post_key(),
      stamp_source_behaviour: false,
      reject_old: true,
      arg_naming_hint?: false
    }
  end
end
