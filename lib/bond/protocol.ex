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

  alias Bond.Compiler.EnvSnapshot
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context
  alias Bond.Compiler.ProtocolWrapper

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
    InheritedContracts.accumulate_pending(ctx(), kind, expression, __CALLER__, meta)
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
    leftover_pre = InheritedContracts.pending(ctx(), env.module, :precondition)
    leftover_post = InheritedContracts.pending(ctx(), env.module, :postcondition)

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
        ProtocolWrapper.build_wrapper(env.module, name, arity, arg_names, pre, post)
      end

    # Emit a reflection function so `Bond.Protocol.Impl` can read the protocol's contracts at
    # impl compile time (the protocol is always compiled before its impls). Assertions are
    # sanitized with `EnvSnapshot` before escaping — a live `Macro.Env` carries a pid
    # (`:lexical_tracker`) that has no quoted form.
    contract_clauses =
      for {{name, arity}, arg_names, pre, post} <- contracts do
        sanitized_pre = Enum.map(pre, &EnvSnapshot.sanitize_assertion/1)
        sanitized_post = Enum.map(post, &EnvSnapshot.sanitize_assertion/1)

        quote do
          @doc false
          def __bond_protocol_contract__(unquote(name), unquote(arity)) do
            {unquote(Macro.escape(arg_names)),
             unquote(Macro.escape(sanitized_pre)),
             unquote(Macro.escape(sanitized_post))}
          end
        end
      end

    catch_all =
      quote do
        @doc false
        def __bond_protocol_contract__(_name, _arity), do: :no_contract
      end

    {:__block__, [], wrappers ++ contract_clauses ++ [catch_all]}
  end

  # The shared inheritance plumbing (pending accumulation, reference validation, diagnostics)
  # lives in `Bond.Compiler.InheritedContracts`; this context tells it how the protocol flavour
  # differs from the behaviour flavour. Protocols reject `old/1` (the dispatch wrapper snapshots
  # no entry state — a v1 non-goal) and attribute failures via source_protocol/impl at the
  # dispatch layer rather than stamping source_behaviour.
  defp ctx do
    %Context{
      noun: "function",
      contract_subject: "protocol function",
      reference_scope: "its named arguments",
      pending_pre_key: pending_pre_key(),
      pending_post_key: pending_post_key(),
      reject_old: true
    }
  end

  # --- internal: record a function's contracts ---

  defp register_function_contracts(name, args, %Macro.Env{} = env) do
    pre = InheritedContracts.pending(ctx(), env.module, :precondition)
    post = InheritedContracts.pending(ctx(), env.module, :postcondition)

    InheritedContracts.clear_pending(ctx(), env.module)

    if pre != [] or post != [] do
      arg_names = canonical_arg_names(args)

      InheritedContracts.validate_referenced_names!(
        ctx(),
        pre,
        post,
        {name, length(args)},
        arg_names,
        env
      )

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
end
