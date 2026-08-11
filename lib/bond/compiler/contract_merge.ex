defmodule Bond.Compiler.ContractMerge do
  @moduledoc internal: true
  @moduledoc """
  Folds *externally sourced* contracts into a function's own, at the using module's
  `@before_compile`.

  By the time `Bond.Compiler.__before_compile__/1` runs, an `AnnotatedFunction` carries whatever
  `@pre`/`@post`/`@pre_weaken`/`@post_strengthen` were written directly on it. Two other sources
  may also apply, and this module resolves both:

    * **Behaviour inheritance** (`use Bond, behaviours: […]`) — `merge_inherited_contract/2`
      replaces the function's contracts with the callback's, rebinds its parameters to the
      callback's canonical argument names, and folds any deliberate refinement per Eiffel's
      variance rules (#16).

    * **Named contracts** (`@apply_contract`, #35) — `merge_applied_contract/3` resolves the
      reference (local or remote), attaches the contract's clauses, and rebinds parameters to the
      contract's canonical names.

  Both are, structurally, the same operation: adopt someone else's contract and speak in their
  vocabulary. They are kept as two functions ("Option B") because their *rules* differ — what may
  be added, what may be refined, and what combination is a v1 non-goal — and because each owns a
  distinct set of compile-time diagnostics. Every constraint either enforces a behavioural-subtyping
  rule or names an explicit non-goal, so the error text is as much of this module as the folding is.

  Extracted from `Bond.Compiler` so that module stays what its own docs describe: the
  `@on_definition` / `@before_compile` / `@after_compile` hook handler. This is only reachable
  from `Bond.Compiler.__before_compile__/1`, never from a user module's AST, so it adds no
  compile-time dependency to modules that `use Bond`.
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.InheritedContracts
  alias Bond.Compiler.InheritedContracts.Context
  alias Bond.Compiler.NamedContracts

  @doc """
  Attaches a behaviour's inherited contracts to the matching implementation function.

  The match is purely on `{name, arity}` — independent of whether the impl wrote `@impl true` —
  and fires only for callbacks the module actually implements, so optional callbacks the impl
  skips contribute nothing.

  An impl may not attach a *plain* `@pre`/`@post` to an inherited operation: a plain impl-level
  precondition would strengthen the inherited one, breaking Liskov substitutability. That stays a
  compile error. It MAY deliberately refine the inherited contract with `@pre_weaken` (effective
  pre = inherited OR weaken) or `@post_strengthen` (effective post = inherited AND strengthen)
  (#16); those are partitioned off here and folded by the codegen. A refinement that targets a
  non-inherited function, or a `@pre_weaken` with no inherited precondition to weaken, is itself a
  compile error.

  A function that applies a named contract (`@apply_contract`, #35) is handled entirely by
  `merge_applied_contract/3`, which owns its own diagnostics and v1 constraints; it is skipped
  here so the two paths never both process one function. (Combining the two is itself a v1
  non-goal, caught in `merge_applied_contract/3`.)
  """
  @spec merge_inherited_contract(AnnotatedFunction.t(), map()) :: AnnotatedFunction.t()
  def merge_inherited_contract(%AnnotatedFunction{applied_contracts: [_ | _]} = af, _inherited),
    do: af

  def merge_inherited_contract(%AnnotatedFunction{} = annotated_function, inherited) do
    key = {annotated_function.fun, annotated_function.arity}

    {plain_pre, weaken_pre} = partition_refinements(annotated_function.preconditions)
    {plain_post, strengthen_post} = partition_refinements(annotated_function.postconditions)

    case Map.fetch(inherited, key) do
      :error ->
        # Not an inherited operation: `@pre_weaken`/`@post_strengthen` have nothing to refine.
        if weaken_pre != [] or strengthen_post != [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: nothing_to_refine_message(annotated_function)
        end

        annotated_function

      {:ok, %{arg_names: names, preconditions: inherited_pre, postconditions: inherited_post}} ->
        if plain_pre != [] or plain_post != [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: immutable_contract_message(annotated_function)
        end

        if weaken_pre != [] and inherited_pre == [] do
          raise CompileError,
            file: inherited_violation_file(annotated_function),
            line: inherited_violation_line(annotated_function),
            description: nothing_to_weaken_message(annotated_function)
        end

        reject_old_in_strengthen!(strengthen_post, annotated_function)

        validate_refinement_references!(
          weaken_pre,
          strengthen_post,
          key,
          names,
          annotated_function
        )

        annotated_function
        |> AnnotatedFunction.replace_preconditions(inherited_pre)
        |> AnnotatedFunction.replace_postconditions(inherited_post)
        |> AnnotatedFunction.put_pre_weaken(weaken_pre)
        |> AnnotatedFunction.put_post_strengthen(strengthen_post)
        |> AnnotatedFunction.put_canonical_override(names)
    end
  end

  @doc """
  Resolves and folds an applied named contract (`@apply_contract`, #35) into a function.

  Kept separate from `merge_inherited_contract/2` ("Option B"): it speaks in "contract" terms and
  makes the v1 non-goals explicit compile errors. The fold itself is identical in spirit to
  inheriting a behaviour contract verbatim — replace the function's pre/post with the contract's,
  and rebind its parameters to the contract's canonical argument names positionally.
  """
  @spec merge_applied_contract(AnnotatedFunction.t(), map(), map()) :: AnnotatedFunction.t()
  def merge_applied_contract(%AnnotatedFunction{applied_contracts: []} = af, _inherited, _named),
    do: af

  def merge_applied_contract(
        %AnnotatedFunction{applied_contracts: applied} = af,
        inherited,
        named
      ) do
    key = {af.fun, af.arity}
    [%{env: apply_env} | _] = applied

    # v1 non-goal: a single applied contract per function (composing several would require the
    # canonical-name agreement / multi-binding the immutable v1 deliberately omits).
    if length(applied) > 1 do
      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: #{mfa(af)} applies more than one named contract. Applying multiple named " <>
            "contracts to one function is not supported (v1); apply a single contract."
    end

    [%{ref: ref}] = applied
    {contract_module, name, entry} = resolve_applied_ref(ref, key, af, named, apply_env)

    {plain_pre, weaken_pre} = partition_refinements(af.preconditions)
    {plain_post, strengthen_post} = partition_refinements(af.postconditions)

    label = contract_label(contract_module, name, af.module)

    # Deferred (#40): refining an applied contract with @pre_weaken/@post_strengthen (the OR/weaken
    # case). Additive plain @pre/@post (below) covers the common "also require X" need; weakening
    # stays a compile error for now.
    if weaken_pre != [] or strengthen_post != [] do
      raise CompileError,
        file: apply_env.file,
        line: apply_env.line,
        description:
          "Bond: #{mfa(af)} refines the applied named contract #{label} with " <>
            "@pre_weaken/@post_strengthen. Refining a named contract is not supported (v1)."
    end

    if Map.has_key?(inherited, key) do
      # Combined: @apply_contract on a function that also inherits a behaviour contract (#61).
      # Only zero-argument (result-only) contracts may combine with inheritance; their
      # postconditions are added alongside the inherited ones (equivalent to @post_strengthen).
      if entry.arg_names != [] do
        raise CompileError,
          file: apply_env.file,
          line: apply_env.line,
          description:
            "Bond: #{mfa(af)} both inherits a behaviour contract and applies a named contract " <>
              "(@apply_contract). Only zero-argument (result-only) contracts may combine with " <>
              "behaviour inheritance — their postconditions are added as a strengthening. " <>
              "Use @post_strengthen for contracts with arguments, or remove the behaviour " <>
              "from the `behaviours:` list to use @apply_contract alone."
      end

      if plain_pre != [] or plain_post != [] do
        raise CompileError,
          file: apply_env.file,
          line: apply_env.line,
          description:
            "Bond: #{mfa(af)} combines @apply_contract with additional @pre/@post alongside " <>
              "an inherited behaviour contract. Use @post_strengthen for the extra assertions."
      end

      {:ok, %{arg_names: inh_names, preconditions: inh_pre, postconditions: inh_post}} =
        Map.fetch(inherited, key)

      source = {contract_module, name}

      af
      |> AnnotatedFunction.replace_preconditions(inh_pre)
      |> AnnotatedFunction.replace_postconditions(inh_post)
      |> AnnotatedFunction.put_post_strengthen(
        stamp_source_contract(entry.postconditions, source)
      )
      |> AnnotatedFunction.put_canonical_override(inh_names)
    else
      # Non-combined: no inherited contract on this function. Pure @apply_contract path.

      # #40 Option A: the function's own plain @pre/@post ADD to the applied contract (conjunction).
      # They evaluate in the lifted assertion defp, which is parameterised by the contract's canonical
      # argument names — so they must reference those names, not the function's own parameters. Validate
      # that here (a clear error beats an "undefined variable" deep in generated code), then append them
      # UNSTAMPED so a failure attributes to the function itself, not the contract.
      validate_applied_extension_refs!(
        plain_pre,
        plain_post,
        {af.fun, af.arity},
        entry.arg_names,
        apply_env
      )

      source = {contract_module, name}

      af
      |> AnnotatedFunction.replace_preconditions(
        stamp_source_contract(entry.preconditions, source) ++ plain_pre
      )
      |> AnnotatedFunction.replace_postconditions(
        stamp_source_contract(entry.postconditions, source) ++ plain_post
      )
      |> then(fn af ->
        if entry.arg_names == [],
          # Zero-argument result-only contract: leave canonical_names_override nil so the wrapper
          # and super call use the function's own parameters. The lifted defp receives those params
          # but underscore-prefixes them in its head (see AnnotatedFunction.lifted_defp_params/3).
          do: AnnotatedFunction.put_result_only_contract(af),
          else: AnnotatedFunction.put_canonical_override(af, entry.arg_names)
      end)
    end
  end

  defp validate_applied_extension_refs!([], [], _key, _arg_names, _env), do: :ok

  defp validate_applied_extension_refs!(plain_pre, plain_post, key, arg_names, env) do
    InheritedContracts.validate_referenced_names!(
      applied_extension_ctx(),
      plain_pre,
      plain_post,
      key,
      arg_names,
      env
    )
  end

  # Reference-validation context for plain @pre/@post added alongside an @apply_contract (#40).
  # Validation-only (see `Context`): the assertions are already in hand, so only the
  # diagnostic-wording fields matter. `reject_old` stays false — `old/1` is fine in an added
  # @post, same as on any ordinary function.
  defp applied_extension_ctx do
    %Context{
      noun: "contract",
      contract_subject: "function applying a named contract",
      reference_scope: "the applied contract's argument names"
    }
  end

  defp resolve_applied_ref(
         {:local, name},
         {_fun, arity},
         %AnnotatedFunction{module: module},
         named,
         env
       ) do
    fetch_applied_entry(named, name, arity, module, env)
  end

  defp resolve_applied_ref({:remote, contract_module, name}, {_fun, arity}, _af, _named, env) do
    contract_module
    |> NamedContracts.remote_registry!(
      env,
      NamedContracts.no_named_contracts_message(contract_module, name)
    )
    |> fetch_applied_entry(name, arity, contract_module, env)
  end

  defp fetch_applied_entry(registry, name, arity, contract_module, env) do
    case NamedContracts.fetch_entry(registry, name, arity) do
      {:ok, entry} ->
        {contract_module, name, entry}

      :error ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: unknown_applied_contract_message(registry, name, arity, contract_module)
    end
  end

  defp unknown_applied_contract_message(registry, name, arity, contract_module) do
    available =
      registry
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {n, a} -> "#{n}/#{a}" end)

    available_phrase =
      if available == "", do: "it defines no named contracts", else: "available: #{available}"

    "Bond: no named contract #{name}/#{arity} in #{inspect(contract_module)} (#{available_phrase})."
  end

  defp stamp_source_contract(assertions, source) do
    Enum.map(assertions, fn assertion -> %{assertion | source_contract: source} end)
  end

  defp contract_label(contract_module, name, function_module) do
    if contract_module == function_module,
      do: inspect(name),
      else: "#{inspect(contract_module)}.#{name}"
  end

  defp mfa(%AnnotatedFunction{module: module, fun: fun, arity: arity}),
    do: "#{inspect(module)}.#{fun}/#{arity}"

  # Splits a function's own assertions into {plain, refinement} by the `:refinement` tag the
  # `@pre_weaken`/`@post_strengthen` macros set (`nil` => plain `@pre`/`@post`).
  defp partition_refinements(assertions) do
    Enum.split_with(assertions, fn %Assertion{refinement: r} -> is_nil(r) end)
  end

  # `@post_strengthen` runs in the lifted postcondition defp without `old/1` precompilation, so
  # reject `old(...)` rather than letting it surface as an "undefined function old/1" deep in
  # generated code. The inherited postcondition may still use `old/1` as before.
  defp reject_old_in_strengthen!(strengthen_post, annotated_function) do
    if Enum.any?(strengthen_post, &InheritedContracts.uses_old?(&1.expression)) do
      raise CompileError,
        file: inherited_violation_file(annotated_function),
        line: inherited_violation_line(annotated_function),
        description: old_in_strengthen_message(annotated_function)
    end

    :ok
  end

  # `@pre_weaken`/`@post_strengthen` reference the abstraction's canonical argument names — the same
  # names the inherited contract uses — so validate them against those names (plus `result` in the
  # strengthening postcondition). Caught here, a typo points at the refinement; left to the codegen
  # it would surface as an opaque "undefined variable" inside the generated lifted defp. Shares the
  # protocol path's `InheritedContracts.validate_referenced_names!` so both flavours diagnose
  # bad references identically.
  defp validate_refinement_references!([], [], _key, _names, _annotated_function), do: :ok

  defp validate_refinement_references!(
         weaken_pre,
         strengthen_post,
         key,
         names,
         annotated_function
       ) do
    [clause | _] = annotated_function.clauses

    InheritedContracts.validate_referenced_names!(
      refinement_ctx(),
      weaken_pre,
      strengthen_post,
      key,
      names,
      clause.env
    )
  end

  # Validation-only `Context` (see `Context`) shaping the unknown-reference diagnostic for a
  # behaviour-impl refinement. `reject_old` stays `false`: `old/1` in `@post_strengthen` is
  # rejected separately by `reject_old_in_strengthen!/2`, and the inherited `@post` may
  # legitimately use it.
  defp refinement_ctx do
    %Context{
      noun: "callback",
      contract_subject: "behaviour implementation",
      reference_scope: "the callback's named arguments"
    }
  end

  defp inherited_violation_file(%AnnotatedFunction{clauses: [clause | _]}), do: clause.env.file
  defp inherited_violation_file(_), do: nil

  defp inherited_violation_line(%AnnotatedFunction{clauses: [clause | _]}), do: clause.env.line
  defp inherited_violation_line(_), do: nil

  defp immutable_contract_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` inherits a contract from a behaviour, so it may not declare its " <>
      "own `@pre`/`@post` (a plain impl-level precondition would strengthen the inherited one, " <>
      "violating Liskov substitutability). To deliberately refine the inherited contract, use " <>
      "`@pre_weaken` (weakens the inherited precondition) or `@post_strengthen` (strengthens the " <>
      "inherited postcondition). For an implementation-specific assertion independent of the " <>
      "contract, use `check/1` in the function body instead."
  end

  defp nothing_to_refine_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` uses `@pre_weaken`/`@post_strengthen` but inherits no contract to " <>
      "refine. Refinement only applies to a function that inherits a `@pre`/`@post` from a " <>
      "behaviour callback. Use plain `@pre`/`@post` for a contract on a non-inherited function."
  end

  defp nothing_to_weaken_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: `#{fun}/#{arity}` uses `@pre_weaken` but the inherited contract declares no " <>
      "precondition to weaken. An implementation may not introduce a precondition on an " <>
      "inherited operation — that would strengthen it, violating Liskov substitutability. " <>
      "Use `@post_strengthen` to strengthen the postcondition, or `check/1` in the body for an " <>
      "implementation-specific assertion."
  end

  defp old_in_strengthen_message(%AnnotatedFunction{fun: fun, arity: arity}) do
    "Bond: the `@post_strengthen` on `#{fun}/#{arity}` uses `old/1`, which is not supported in a " <>
      "refinement postcondition. `old/1` is available in the inherited `@post` (on the behaviour " <>
      "callback) but not in the implementation's `@post_strengthen`."
  end
end
