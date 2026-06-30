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

  ## Inheriting verbatim

  By default an implementation inherits its callbacks' contracts **verbatim**. Attaching a plain
  `@pre`/`@post` to an impl function whose `{name, arity}` matches an inherited contract is a
  compile error: a plain impl-level precondition would *strengthen* the inherited one, which
  breaks Liskov substitutability. For an implementation-specific assertion that is independent of
  the contract, use `Bond.check/1` in the body.

  ## Refining inherited contracts (`@pre_weaken` / `@post_strengthen`)

  An implementation may *deliberately refine* what it inherits, following Eiffel's
  behavioural-subtyping rules. Two distinct annotations make the (counterintuitive) variance
  explicit:

    * `@pre_weaken` — **weakens** the precondition. The effective precondition is
      `inherited or pre_weaken`: the impl accepts everything the abstraction promised, and *more*.
      (Preconditions may only weaken down a hierarchy — contravariance.)
    * `@post_strengthen` — **strengthens** the postcondition. The effective postcondition is
      `inherited and post_strengthen`: callers get at least the abstract guarantee, and *more*.
      (Postconditions may only strengthen — covariance.)

  Refinement expressions reference the **callback's** argument names — the same vocabulary as the
  inherited contract they amend — not the implementation's own parameter names. The implementation
  may still name its parameters however it likes; the refinement just binds by the callback's
  names. (Protocol refinement via `Bond.Protocol.Impl` follows the identical rule.)

      defmodule SavingsAccount do
        use Bond, behaviours: [Ledger]   # callback: withdraw(balance, amount)

        # 'amount' is Ledger's callback argument name, even though this clause names it 'amt'.
        @impl true
        @pre_weaken small_withdrawal: amount == 0     # effective pre  = Ledger's OR this
        @post_strengthen audited: log_exists?(result) # effective post = Ledger's AND this
        def withdraw(bal, amt), do: ...
      end

  A refinement only applies to a function that inherits a contract. `@pre_weaken` requires an
  inherited precondition to weaken (you may not *introduce* one — that would strengthen);
  `@post_strengthen` may add a postcondition where the callback declared none. `old/1` is not
  available in `@post_strengthen` (it remains available in the inherited `@post`).

  ## Reflection

  `use Bond.Behaviour` generates a `__bond_contracts__/0` function on the behaviour module that
  returns its callback contracts keyed by `{name, arity}`. It is an internal reflection hook
  read by `use Bond, behaviours: […]` at the implementer's compile time; you should not call
  it directly.
  """

  alias Bond.Compiler.EnvSnapshot
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context

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

  # `@pre`/`@post where(...)`/`whenever(...)` (#47): accumulate the binding group as pending
  # contracts for the next `@callback`, mirroring the direct path. Matched before the single-arg
  # clause so a no-body `@post where(...)` is diagnosed by the shared parser rather than stashed.
  defmacro @{pre_or_post, meta, [{binder, _, [binding]} | scoped]}
           when pre_or_post in [:pre, :post] and binder in [:where, :whenever] do
    kind = if pre_or_post == :pre, do: :precondition, else: :postcondition

    InheritedContracts.accumulate_pending_binding_group(
      ctx(),
      kind,
      binder,
      binding,
      scoped,
      __CALLER__,
      meta
    )

    :ok
  end

  # `@pre`/`@post`: accumulate as pending contracts for the next `@callback`. Supports the bare
  # form (`@pre amount > 0`) and the keyword-list form (`@pre positive: amount > 0`), mirroring
  # the `use Bond` syntax. Expands to `:ok` — the contract is stashed in a module attribute at
  # expansion time, it produces no runtime code here.
  defmacro @{pre_or_post, meta, [expression]} when pre_or_post in [:pre, :post] do
    kind = if pre_or_post == :pre, do: :precondition, else: :postcondition
    InheritedContracts.accumulate_pending(ctx(), kind, expression, __CALLER__, meta)
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
    leftover_pre = InheritedContracts.pending(ctx(), env.module, :precondition)
    leftover_post = InheritedContracts.pending(ctx(), env.module, :postcondition)

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

  # The shared inheritance plumbing (pending accumulation, reference validation, diagnostics)
  # lives in `Bond.Compiler.InheritedContracts`; this context tells it how the behaviour flavour
  # differs from the protocol flavour.
  defp ctx do
    %Context{
      noun: "callback",
      contract_subject: "behaviour callback",
      reference_scope: "the callback's named arguments",
      pending_pre_key: :__bond_pending_pre__,
      pending_post_key: :__bond_pending_post__,
      stamp_source_behaviour: true,
      arg_naming_hint?: true
    }
  end

  # --- internal: callback parsing + contract registration ---

  defp register_callback_contracts(spec, %Macro.Env{} = env) do
    pre = InheritedContracts.pending(ctx(), env.module, :precondition)
    post = InheritedContracts.pending(ctx(), env.module, :postcondition)

    InheritedContracts.clear_pending(ctx(), env.module)

    # Only record an entry when this callback actually carries contracts — uncontracted
    # callbacks contribute nothing for implementers to inherit.
    if pre != [] or post != [] do
      case parse_callback(spec) do
        {name, arity, arg_names} ->
          InheritedContracts.validate_referenced_names!(
            ctx(),
            pre,
            post,
            {name, arity},
            arg_names,
            env
          )

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

  # --- internal: contract collection ---

  defp collect_contracts(module) do
    (Module.get_attribute(module, :__bond_callback_contracts__) || [])
    |> Enum.reverse()
    |> Map.new(fn {key, entry} -> {key, EnvSnapshot.sanitize_contract_entry(entry)} end)
  end
end
