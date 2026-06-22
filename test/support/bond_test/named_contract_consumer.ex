defmodule BondTest.NamedContractConsumer do
  @moduledoc """
  Applies named contracts from `BondTest.NamedContractLibrary` across a real compile-module
  boundary, with the contract module referenced through an `alias` (so `@apply_contract` exercises
  alias expansion in the caller's context).
  """

  use Bond

  alias BondTest.NamedContractLibrary

  @apply_contract {NamedContractLibrary, :withdrawal}
  def withdraw(acct, amt), do: %{acct | balance: acct.balance - amt}

  @apply_contract {NamedContractLibrary, :positive}
  def only_positive(n), do: n

  @apply_contract {NamedContractLibrary, :positive}
  def above_floor(n, floor), do: n - floor
end
