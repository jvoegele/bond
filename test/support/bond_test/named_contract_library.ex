defmodule BondTest.NamedContractLibrary do
  @moduledoc """
  Reusable named contracts shared across modules, for cross-module `@apply_contract` tests.

  Compiled by `mix` (not in-memory via `Code.compile_string`), so the consumer
  (`BondTest.NamedContractConsumer`) exercises the real compile-time dependency edge: it reads
  this module's `__bond_named_contracts__/0` at its own compile time, which requires this module
  to be compiled first.
  """

  use Bond

  defcontract withdrawal(account, amount) do
    @pre positive: amount > 0
    @pre sufficient: amount <= account.balance
    @post non_negative: result.balance >= 0
  end

  # Same name, different arities — the applying function's arity selects the overload.
  defcontract positive(x) do
    @pre x > 0
  end

  defcontract positive(x, floor) do
    @pre x > floor
  end
end
