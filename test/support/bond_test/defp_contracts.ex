defmodule BondTest.DefpContracts do
  @moduledoc """
  Fixture exercising contracts on private (`defp`) helpers. Pre-0.16.2,
  attaching `@pre`/`@post` to a `defp` emitted an `@doc` attribute that
  Elixir then warned about ("module attribute @doc was set but never
  used" / "@doc is always discarded for private functions"), making the
  combination unusable without noise. 0.16.2's `ContractDocs.doc_clauses/4`
  skips emission entirely when `kind` is `:defp`.

  The contracts themselves continue to fire — `defp` was always
  supported, just noisy.
  """

  use Bond

  def encode(x), do: encode_value(x)

  def double(x), do: doubled_int(x)

  @pre is_integer(x)
  @post result == x * 2
  defp doubled_int(x), do: x * 2

  @pre is_number(x)
  @pre x >= 0
  defp encode_value(x), do: :math.sqrt(x)
end
