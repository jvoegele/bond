defmodule Bond.Compiler.Config do
  @moduledoc internal: true
  @moduledoc """
  Resolves the per-module contract configuration a `use Bond` module compiles under.

  Three layers feed in — the global `:bond` application config, any `:overrides` entry matching
  the module, and the options passed to `use Bond` — and `resolve/3` collapses them into the
  single `t:contract_config/0` map that every codegen path reads. Resolution happens once per
  module, in the *user's* module body (so `Application.compile_env/3` tracks the dependency for
  recompilation), and the result is stashed in `@__bond_contract_config__`.

  This is compile-time policy only: which kinds are compiled in, compiled out, or compiled with a
  runtime gate. The runtime half of the same question lives in `Bond.Runtime.Eval`.

  > #### Reached through `Bond.Compiler` {: .info}
  >
  > A `use Bond` module's AST names `Bond.Compiler.resolve_config/3`, never this module directly.
  > That indirection is deliberate: every module reference a `use Bond` expansion emits becomes a
  > compile-time dependency subject to the parallel compiler's scheduling, and this codebase has
  > repeatedly been bitten by adding one. Keeping the reference on the already-required
  > `Bond.Compiler` leaves that dependency surface exactly as it was.
  """

  @typedoc """
  Per-kind compilation mode. See `Bond.Compiler.AnnotatedFunction.mode/0`.
  """
  @type mode :: true | false | :purge

  @typedoc """
  Resolved per-module configuration produced by `resolve/3` and stashed in the using module's
  `@__bond_contract_config__` attribute.
  """
  @type contract_config :: %{
          preconditions: mode(),
          postconditions: mode(),
          checks: mode(),
          invariants: mode(),
          warn_skipped_invariants: boolean()
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
          {MyApp.HotPath, preconditions: :purge, postconditions: :purge, invariants: :purge},
          {~r/Workers\\./, postconditions: false}
        ]
  """
  @spec resolve(module(), keyword(), keyword()) :: contract_config()
  def resolve(module, use_opts, global) do
    overrides = Keyword.get(global, :overrides, [])

    base = %{
      preconditions: Keyword.fetch!(global, :preconditions),
      postconditions: Keyword.fetch!(global, :postconditions),
      checks: Keyword.fetch!(global, :checks),
      invariants: Keyword.get(global, :invariants, true),
      warn_skipped_invariants: Keyword.get(global, :warn_skipped_invariants, true),
      warn_unavailable_preconditions: Keyword.get(global, :warn_unavailable_preconditions, true)
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
    config
    |> apply_kind_settings(settings)
    |> apply_boolean_settings(settings, [
      :warn_skipped_invariants,
      :warn_unavailable_preconditions
    ])
  end

  defp apply_kind_settings(config, settings) do
    Enum.reduce([:preconditions, :postconditions, :checks, :invariants], config, fn key, acc ->
      case Keyword.fetch(settings, key) do
        {:ok, value} when value in [true, false, :purge] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp apply_boolean_settings(config, settings, keys) do
    Enum.reduce(keys, config, fn key, acc ->
      case Keyword.fetch(settings, key) do
        {:ok, value} when is_boolean(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end
end
