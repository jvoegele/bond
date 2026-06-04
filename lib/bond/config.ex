defmodule Bond.Config do
  @moduledoc """
  Runtime control over which kinds of contract Bond evaluates.

  Bond has two configuration layers:

    * **Compile-time** — `config :bond, <kind>: true | false | :purge` (read via
      `Application.compile_env/3`), plus per-module `:overrides` and `use Bond` options.
      These are baked into each generated call site. `:purge` removes a kind's code
      entirely (zero runtime cost, not toggleable). See `Bond` for the full set of keys.

    * **Runtime** — this module. `enable/1`, `disable/1`, and `put/2` flip a kind on or off
      globally without recompiling. The state lives in a single `:persistent_term` entry
      read on every contracted call, so the gate stays cheap.

  ## Kinds

  `:preconditions`, `:postconditions`, `:invariants`, and `:checks` (for `Bond.check/1,2`).

  ## How runtime and compile-time interact

  On first use the runtime state is seeded from application env, so `config :bond, …` in
  both `config.exs` and `config/runtime.exs` is honoured. A kind with no global setting is
  `:unset` and falls back to the call site's compile-time default (including per-module
  `:overrides`). A value set here overrides that fallback until `reset/0`.

  > #### Runtime `Application.put_env` is not live {: .warning}
  >
  > Setting `Application.put_env(:bond, :preconditions, false)` *after* the first contracted
  > call has run has no effect — the runtime state is cached. Use `disable/1` / `enable/1`,
  > or call `reset/0` to re-seed from current application env.

  ## The chain

  Bond enforces `preconditions ≤ postconditions ≤ invariants`: disabling a lower kind also
  skips the higher ones (with a one-time log). These setters are pure writes — they do not
  cascade; the chain is applied when contracts are evaluated. To turn everything off, disable
  `:preconditions` (or each kind explicitly).

  ## Examples

      # Disable precondition checks globally at runtime
      Bond.Config.disable(:preconditions)

      # Re-enable
      Bond.Config.enable(:preconditions)

      # Inspect the effective global state
      Bond.Config.all()
      #=> %{preconditions: false, postconditions: true, invariants: true, checks: true}

      # Drop all runtime overrides, re-seeding from application env
      Bond.Config.reset()

  > #### Performance note {: .tip}
  >
  > Each `put/2`/`enable/1`/`disable/1`/`reset/0` writes `:persistent_term`, which triggers
  > a global GC scan. This is fine for setup and occasional toggles; do not toggle per call.
  """

  alias Bond.Runtime.Eval

  @kinds [:preconditions, :postconditions, :invariants, :checks]

  @typedoc "A contract kind that can be toggled at runtime."
  @type kind :: :preconditions | :postconditions | :invariants | :checks

  @doc "The list of contract kinds this module controls."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Enables runtime evaluation of `kind`. Equivalent to `put(kind, true)`."
  @spec enable(kind()) :: :ok
  def enable(kind) when kind in @kinds, do: Eval.put_mode(kind, true)

  @doc "Disables runtime evaluation of `kind`. Equivalent to `put(kind, false)`."
  @spec disable(kind()) :: :ok
  def disable(kind) when kind in @kinds, do: Eval.put_mode(kind, false)

  @doc """
  Sets the global runtime mode for `kind` to `enabled?`.

  Overrides both the application-env seed and the call site's compile-time default until
  `reset/0`.
  """
  @spec put(kind(), boolean()) :: :ok
  def put(kind, enabled?) when kind in @kinds and is_boolean(enabled?) do
    Eval.put_mode(kind, enabled?)
  end

  @doc """
  Returns whether `kind` is enabled in the global runtime state.

  Reflects the global setting only; modules compiled with per-module `:overrides` may differ
  at their own call sites. When `kind` has no global setting, falls back to the application
  env default (and `true` if none is configured).
  """
  @spec enabled?(kind()) :: boolean()
  def enabled?(kind) when kind in @kinds do
    case Map.get(Eval.modes(), kind, :unset) do
      :unset -> Application.get_env(:bond, kind, true) != false
      value -> value != false
    end
  end

  @doc """
  Returns the effective global runtime state for every kind as a map of booleans.

  Like `enabled?/1`, this is the global view and does not reflect per-module `:overrides`.
  """
  @spec all() :: %{kind() => boolean()}
  def all, do: Map.new(@kinds, fn kind -> {kind, enabled?(kind)} end)

  @doc """
  Drops all runtime overrides set through this module, re-seeding from current application
  env on the next contracted call. Useful in tests to restore a clean baseline.
  """
  @spec reset() :: :ok
  def reset, do: Eval.reset()
end
