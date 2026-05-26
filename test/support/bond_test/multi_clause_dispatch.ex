defmodule BondTest.MultiClauseDispatch do
  @moduledoc """
  Fixture exercising 0.17.0's per-clause wrapper emission for multi-clause
  functions with contracts.

    * `lookup/2` — shape-dispatching clauses with consistent top-level
      naming (`conn`, `resource`). Uses `~>` implication contracts so each
      assertion only fires for the shape it applies to.

    * `try_init/1` — clause 1 binds `capacity`, clause 2 uses a wildcard.
      Bond's wildcard-adopts-canonical rule lets this compile cleanly with
      `capacity` as the canonical name across both clauses.

    * `parse/1` — single clause with a destructure-in-head pattern. The
      wrapper's head is rewritten so the destructured names (`first`,
      `rest`) are underscore-prefixed, suppressing Elixir's
      "unused variable" warning — but the lifted assertion defp still
      binds them for contract-side access.

    * `concat_or_pass/2` — three clauses with consistent naming and shape
      dispatch via guards. Demonstrates the >=3-clause case.
  """

  use Bond

  defstruct [:id, :tag]

  @pre is_struct(resource, __MODULE__) ~> (resource.id > 0)
  @pre is_binary(resource) ~> (String.length(resource) > 0)
  def lookup(conn, %__MODULE__{} = resource), do: {:ok, conn, resource}
  def lookup(conn, resource) when is_binary(resource), do: {:string, conn, resource}

  @pre is_integer(capacity) ~> (capacity >= 0)
  def try_init(capacity) when is_integer(capacity) and capacity >= 0 do
    {:ok, %{capacity: capacity}}
  end

  def try_init(_), do: {:error, :invalid_capacity}

  @pre is_list(input)
  @post is_atom(result)
  def parse([first | rest]) when first in [:a, :b, :c] do
    first
  end

  def parse(input) when is_list(input) do
    :unknown
  end

  @pre is_struct(item, __MODULE__) ~> (item.id != nil)
  def concat_or_pass([], item), do: [item]
  def concat_or_pass([_ | _] = list, item), do: list ++ [item]
  def concat_or_pass(list, item) when is_list(list), do: list ++ [item]
end
