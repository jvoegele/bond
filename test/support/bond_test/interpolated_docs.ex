defmodule BondTest.InterpolatedDocs do
  @moduledoc "Fixture exercising `@doc` values that need evaluating rather than escaping (#70)."
  use Bond

  defstruct [:x]

  @unit "widgets"

  @doc """
  Builds a %#{__MODULE__}{} measured in #{@unit}.
  """
  @pre pos: x > 0
  @post ok: result.x == x
  def new(x), do: %__MODULE__{x: x}

  # NOTE: no doc-only function here — `@doc` on an uncontracted function in a `use Bond` module
  # is dropped entirely (#71), which is a separate defect on a separate code path.

  @doc "A plain literal doc."
  @pre pos: y > 0
  def twice(y), do: y * 2

  @doc false
  @pre pos: z > 0
  def hidden(z), do: z

  @doc since: "1.0.0"
  @pre pos: n > 0
  def metadata_only(n), do: n
end
