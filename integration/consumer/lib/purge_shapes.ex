defmodule ContractConsumer.PurgeShapes do
  @moduledoc """
  Shapes whose generated code differs between a contracted and a purged build.

  Compiled by the `downstream` CI job twice: normally, and with `MIX_ENV=purged`
  (everything `:purge`d) under `--warnings-as-errors`. Both must be warning-free.

  The module attributes below are read *only* from inside contracts. Purging discards
  those contracts, and before #79 the attributes lost their last reader and warned
  "set but never used" — a warning that appears solely in the build an adopter gates
  on `--warnings-as-errors`, and that names Elixir rather than Bond.
  """

  use Bond

  @limit 100
  @floor 0

  @pre within: amount <= @limit
  def bounded(amount), do: amount

  @post non_negative: result >= @floor
  def clamp(n), do: max(n, @floor)

  defmodule Counter do
    @moduledoc "An `@invariant` reading a module attribute."

    use Bond

    defstruct count: 0

    @ceiling 10

    @invariant under_ceiling: subject.count <= @ceiling

    def new(n) when n <= @ceiling, do: %__MODULE__{count: n}
    def bump(%__MODULE__{} = c), do: %{c | count: c.count + 1}
  end

  @threshold 5

  def checked(n) do
    check above_threshold: n > @threshold
    n
  end
end
