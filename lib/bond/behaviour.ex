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

  alias Bond.Compiler.Clauses
  alias Bond.Compiler.EnvSnapshot
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context
  alias Bond.Compiler.NamedContracts

  @doc false
  defmacro __using__(_opts) do
    quote do
      # Shadow `Kernel.@/1` so Bond can intercept `@pre`/`@post`/`@callback`. Lexically scoped
      # to this module, exactly as `use Bond` scopes its own `@` override.
      import Kernel, except: [@: 1]
      import Bond.Behaviour, only: [@: 1]
      # `defcontract` / `include` are available in the same module, letting the behaviour DRY
      # up repeated postconditions via `@apply_contract` before each `@callback` (#61).
      import Bond, only: [defcontract: 1, defcontract: 2]

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

  # `@apply_contract <ref>` — apply a reusable named contract to the next `@callback` (#61).
  # Stores the ref so `register_callback_contracts` can expand it when the `@callback` fires.
  # Cannot be combined with `@pre`/`@post` on the same `@callback` (checked there).
  defmacro @{:apply_contract, _meta, [expression]} do
    env = __CALLER__
    ref = NamedContracts.parse_ref(expression, env)
    Module.put_attribute(env.module, :__bond_pending_apply_contract__, {ref, env})
    :ok
  end

  # `@apply_contract` with multiple args — the list form is not supported.
  defmacro @{:apply_contract, _meta, [_, _ | _]} do
    raise CompileError,
      file: __CALLER__.file,
      line: __CALLER__.line,
      description:
        "Bond: @apply_contract accepts a single contract reference — a name (`:returns_conn`) " <>
          "or a `{Module, :name}` pair."
  end

  # `@callback`: snapshot the pending `@pre`/`@post` (or `@apply_contract`) and record them
  # against this callback's `{name, arity}`, then forward the spec to `Kernel.@/1` so the
  # callback is registered as usual (the module remains an ordinary behaviour).
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
    InheritedContracts.assert_nothing_pending!(ctx(), env)

    contracts = collect_contracts(env.module)
    named_contracts_ast = named_contracts_reflection_ast(env.module)

    quote do
      @doc false
      def __bond_contracts__, do: unquote(Macro.escape(contracts))
      unquote(named_contracts_ast)
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
      pending_apply_key: :__bond_pending_apply_contract__,
      declaration_form: "@callback",
      stamp_source_behaviour: true,
      arg_naming_hint?: true
    }
  end

  # --- internal: callback parsing + contract registration ---

  # Flushes whatever `@pre`/`@post`/`@apply_contract` preceded this `@callback` and records the
  # resolved contract against its `{name, arity}`. Taking, conflict-checking, named-contract
  # expansion, and reference validation are all shared with `Bond.Protocol` via
  # `InheritedContracts`; what is behaviour-specific is parsing the callback spec and the entry
  # shape stored for `__bond_contracts__/0`.
  defp register_callback_contracts(spec, %Macro.Env{} = env) do
    case InheritedContracts.take_pending!(ctx(), env.module) do
      # Uncontracted callbacks contribute nothing for implementers to inherit.
      :none ->
        :ok

      taken ->
        {name, arity, callback_arg_names} = parse_callback!(spec, env)

        {canonical_names, pre, post} =
          InheritedContracts.resolve_contract!(
            ctx(),
            {name, arity},
            callback_arg_names,
            taken,
            env
          )

        entry =
          {{name, arity}, %{arg_names: canonical_names, preconditions: pre, postconditions: post}}

        current = Module.get_attribute(env.module, :__bond_callback_contracts__) || []
        Module.put_attribute(env.module, :__bond_callback_contracts__, [entry | current])
    end
  end

  defp parse_callback!(spec, env) do
    case parse_callback(spec) do
      {_name, _arity, _arg_names} = parsed ->
        parsed

      :error ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "Bond: could not parse the @callback that the preceding @pre/@post (or " <>
              "@apply_contract) attaches to. Bond contracts require a named callback of the form " <>
              "`@callback name(arg :: type, …) :: return`."
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
  # name; use the generated placeholder `Bond.Compiler.Clauses` owns so the position is still
  # addressable by the positional rebind (contracts simply can't reference it by name — that is
  # what `InheritedContracts.generated_name?/1` recognises).
  defp arg_name({:"::", _meta, [{name, _, ctx}, _type]}, _idx)
       when is_atom(name) and is_atom(ctx),
       do: name

  defp arg_name(_arg, idx), do: Clauses.generated_name(idx)

  # --- internal: contract collection ---

  defp collect_contracts(module) do
    (Module.get_attribute(module, :__bond_callback_contracts__) || [])
    |> Enum.reverse()
    |> Map.new(fn {key, entry} -> {key, EnvSnapshot.sanitize_contract_entry(entry)} end)
  end

  # Emits `__bond_named_contracts__/0` when the behaviour defines at least one `defcontract`,
  # so other modules can reference them with `@apply_contract {BehaviourModule, :name}`.
  # `nil` (no contracts) splices as nothing.
  defp named_contracts_reflection_ast(module) do
    module |> NamedContracts.flatten() |> NamedContracts.reflection_ast()
  end
end
