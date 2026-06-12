defmodule Bond.Compiler.EnvSnapshot do
  @moduledoc internal: true
  @moduledoc """
  Reduces a live `Macro.Env` (and the assertions that carry one) to an escapable snapshot.

  A behaviour module's callback contracts are emitted into its `__bond_contracts__/0`
  reflection function via `Macro.escape/1`. A live `Macro.Env` captured at the `@pre` site
  cannot be escaped — its `:lexical_tracker` is a pid, which has no quoted form. This module
  reduces each assertion's `definition_env` to a fresh `Macro.Env` holding only the fields the
  downstream error machinery reads (file/line/module/function); everything else takes its
  escapable struct default.
  """

  alias Bond.Compiler.Assertion

  @doc """
  Snapshots the `:definition_env` of every assertion in a callback-contract entry's
  `:preconditions` and `:postconditions` lists.
  """
  def sanitize_contract_entry(%{preconditions: pre, postconditions: post} = entry) do
    %{
      entry
      | preconditions: Enum.map(pre, &sanitize_assertion/1),
        postconditions: Enum.map(post, &sanitize_assertion/1)
    }
  end

  @doc """
  Replaces an assertion's live `:definition_env` with an escapable snapshot.
  """
  def sanitize_assertion(%Assertion{definition_env: env} = assertion) do
    %{assertion | definition_env: sanitize_env(env)}
  end

  @doc """
  Reduces a `Macro.Env` to the escapable subset of fields the error machinery reads.
  """
  def sanitize_env(%Macro.Env{} = env) do
    %Macro.Env{file: env.file, line: env.line, module: env.module, function: env.function}
  end
end
