defmodule Bond.Compiler do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for defining contracts for a module at compile-time.

  Bond installs this module as the `@on_definition`, `@before_compile`, and `@after_compile`
  handler for any module that does `use Bond`. As the user's module is being compiled:

    * `@pre`, `@post`, and `@doc` annotations are intercepted by `Bond` and forwarded here via
      `register_assertion/5` and `register_doc/3`. They accumulate in the per-module
      `Bond.Compiler.CompileStateFSM` process.
    * Every `def` and `defp` definition fires `__on_definition__/6`, which builds a
      `Bond.Compiler.FunctionDefinition` and feeds it to the FSM. The FSM groups clauses by
      `{module, fun, arity}` and attaches any pending preconditions/postconditions/docs to the
      resulting `Bond.Compiler.AnnotatedFunction`.
    * `__before_compile__/1` asks the FSM for every `AnnotatedFunction` that has a contract and
      delegates to `AnnotatedFunction.apply_contract/1` to emit a `defoverridable` plus a
      single override clause that wraps the original function in pre/post evaluation.
    * `__after_compile__/2` stops the FSM process.
  """

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.CompileStateFSM, as: FSM
  alias Bond.Compiler.FunctionDefinition

  # Functions Elixir auto-generates as a side effect of constructs like `defstruct` and
  # `defexception`. These show up via `@on_definition` and must not be tracked as user
  # contract candidates.
  @generated_functions ~w[__struct__ __exception__ __info__]a

  @doc false
  def init(module) do
    {:ok, _fsm_pid} = FSM.start_link(module)
    :ok
  end

  @typedoc """
  Per-kind compilation mode. See `Bond.Compiler.AnnotatedFunction.mode/0`.
  """
  @type mode :: true | false | :purge

  @typedoc """
  Resolved per-module configuration produced by `resolve_config/3` and stashed in the
  using module's `@__bond_contract_config__` attribute.
  """
  @type contract_config :: %{
          preconditions: mode(),
          postconditions: mode(),
          checks: mode(),
          invariants: mode()
        }

  @doc """
  Resolve the final per-module contract configuration from global defaults, `:overrides`,
  and the options passed to `use Bond`.

  Precedence (most specific wins):

    1. `use Bond, preconditions: …` options on the using module.
    2. An `:overrides` entry whose key is an exact module atom match.
    3. An `:overrides` entry whose key is a `Regex` that matches the module name
       (first matching pattern in list order wins).
    4. The global `:bond, :preconditions` / `:postconditions` / `:checks` config.

  `:overrides` is a list of `{Module | Regex, keyword_of_settings}` tuples, e.g.:

      config :bond,
        overrides: [
          {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
          {~r/Workers\\./, postconditions: false}
        ]
  """
  @spec resolve_config(module(), keyword(), keyword()) :: contract_config()
  def resolve_config(module, use_opts, global) do
    overrides = Keyword.get(global, :overrides, [])

    base = %{
      preconditions: Keyword.fetch!(global, :preconditions),
      postconditions: Keyword.fetch!(global, :postconditions),
      checks: Keyword.fetch!(global, :checks),
      invariants: Keyword.get(global, :invariants, true)
    }

    resolved =
      base
      |> apply_settings(resolve_overrides_for(overrides, module))
      |> apply_settings(use_opts)

    validate_chain!(module, resolved)
    resolved
  end

  # The contract-checking chain is `preconditions ≤ postconditions ≤ invariants`. If a
  # lower kind is `:purge`, every higher kind must also be `:purge` — there's no
  # meaningful way to compile invariant or postcondition evaluation into the BEAM while
  # the preconditions they presuppose are absent. (`:checks` is independent of the chain.)
  #
  # The runtime half of the constraint — `false` at runtime for a lower kind skipping the
  # higher kinds — is enforced in `Bond.Runtime.Eval.should_evaluate?/3`.
  defp validate_chain!(module, config) do
    chain = [:preconditions, :postconditions, :invariants]

    Enum.reduce(chain, [], fn kind, lower_kinds ->
      if config[kind] != :purge do
        for lower <- lower_kinds, config[lower] == :purge do
          raise CompileError,
            description: chain_error_message(module, kind, lower)
        end
      end

      [kind | lower_kinds]
    end)

    :ok
  end

  defp chain_error_message(module, higher, lower) do
    """
    Bond: contract-checking chain violated for #{inspect(module)}.

    `:#{higher}` is compiled in, but `:#{lower}` is `:purge`d. The chain
    `preconditions ≤ postconditions ≤ invariants` requires that if a higher kind is
    in the BEAM, all lower kinds it presupposes must also be compiled in.

    A `:#{higher}` failure is only meaningful if `:#{lower}` was first verified — without
    `:#{lower}`, a `:#{higher}` error could really be the caller's fault, not the callee's.

    Resolutions:

      * If you want to skip `:#{higher}` evaluation but keep the code, use
        `:#{higher}` => `false` (compiled in, runtime-disabled by default).
      * If you genuinely want `:#{lower}` purged, also purge every higher kind:
        `:#{lower}` => `:purge`, `:#{higher}` => `:purge`.
    """
  end

  defp resolve_overrides_for(overrides, module) do
    case Enum.find(overrides, &exact_match?(&1, module)) do
      {_, opts} ->
        opts

      nil ->
        case Enum.find(overrides, &regex_match?(&1, module)) do
          {_, opts} -> opts
          nil -> []
        end
    end
  end

  defp exact_match?({atom, _opts}, module) when is_atom(atom), do: atom == module
  defp exact_match?(_, _), do: false

  defp regex_match?({%Regex{} = pattern, _opts}, module) do
    Regex.match?(pattern, module_name_for_match(module))
  end

  defp regex_match?(_, _), do: false

  # Module atoms in the BEAM are stored as `"Elixir.MyApp.Foo"`. Strip the `Elixir.` prefix
  # before regex matching so users can write patterns against the source-visible names like
  # `~r/^MyApp\.Workers\./` (rather than `~r/^Elixir\.MyApp\.Workers\./`).
  defp module_name_for_match(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp apply_settings(config, settings) do
    Enum.reduce([:preconditions, :postconditions, :checks, :invariants], config, fn key, acc ->
      case Keyword.fetch(settings, key) do
        {:ok, value} when value in [true, false, :purge] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  @doc false
  def __on_definition__(_env, kind, _fun, _params, _guards, _body)
      when kind in [:defmacro, :defmacrop] do
    # Bond does not (yet) support contracts on macros.
    :ok
  end

  def __on_definition__(_env, _kind, fun, _params, _guards, _body)
      when fun in @generated_functions do
    :ok
  end

  # Bodyless function heads (`def foo(x)` with no `do` block) are used purely to attach
  # docs/specs/contracts to the clauses that follow. They don't produce executable code, so we
  # skip them — the contracts will be picked up by the first body-bearing clause.
  def __on_definition__(_env, kind, _fun, _params, _guards, nil) when kind in [:def, :defp] do
    :ok
  end

  def __on_definition__(env, kind, fun, params, guards, body) when kind in [:def, :defp] do
    function_def = FunctionDefinition.new(env, kind, fun, params, guards, body)
    FSM.function_def(fsm(env), function_def)
  end

  @doc false
  defmacro __before_compile__(%Macro.Env{} = env) do
    :ok = FSM.module_defined(fsm(env))

    config =
      Module.get_attribute(env.module, :__bond_contract_config__) ||
        %{preconditions: true, postconditions: true, invariants: true}

    invariants = FSM.invariants(fsm(env))

    fsm(env)
    |> FSM.annotated_functions()
    |> Enum.map(&AnnotatedFunction.put_invariants(&1, invariants))
    |> Enum.filter(&AnnotatedFunction.override?/1)
    |> Enum.map(&AnnotatedFunction.apply_contract(&1, config))
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    FSM.stop(fsm(env))
  end

  @doc false
  def register_assertion(:pre, expression, label, env, meta) do
    register_assertion(:precondition, expression, label, env, meta)
  end

  def register_assertion(:post, expression, label, env, meta) do
    register_assertion(:postcondition, expression, label, env, meta)
  end

  def register_assertion(kind, expression, label, env, meta) do
    assertion = Assertion.new(kind, label, expression, env, meta)

    fsm_event =
      case kind do
        :precondition -> :precondition_def
        :postcondition -> :postcondition_def
      end

    apply(FSM, fsm_event, [fsm(env), assertion])
  end

  @doc false
  def register_invariant(name, expression, label, env, meta) when is_atom(name) do
    # Strip the hygiene context off every reference to the binding name (`stack` in
    # `@invariant stack, length(stack.items)`). The defp emitted in
    # `Bond.Compiler.Invariants` declares the rebind as `Macro.var(name, nil)`; if the
    # user's references kept their original module context, they would not resolve to
    # that rebind.
    normalized = normalize_binding_context(expression, name)
    meta_with_binding = Keyword.put(meta, :binding_name, name)
    invariant = Assertion.new(:invariant, label, normalized, env, meta_with_binding)
    FSM.invariant_def(fsm(env), invariant)
  end

  defp normalize_binding_context(expression, binding_name) do
    Macro.prewalk(expression, fn
      {^binding_name, meta, ctx} when is_atom(ctx) ->
        {binding_name, meta, nil}

      other ->
        other
    end)
  end

  @doc false
  def register_doc(env, meta, value) do
    FSM.doc_attribute(fsm(env), {meta, value})
  end

  @doc false
  def check_assertion(expression, label, env, meta, mode) when mode in [true, false] do
    check = Assertion.new(:check, label, expression, env, meta)
    body = Assertion.check_body(check)

    quote do
      if Bond.Runtime.Eval.should_evaluate?(:checks, unquote(mode)) do
        Bond.Runtime.Eval.evaluate_check(fn -> unquote(body) end)
      else
        :ok
      end
    end
  end

  @spec fsm(Macro.Env.t()) :: FSM.server_ref()
  defp fsm(%Macro.Env{module: module}), do: FSM.server_ref(module)
end
