defmodule BondTest.HiddenModuledocFixture do
  @moduledoc false

  use Bond

  defstruct [:n]

  @invariant non_negative: subject.n >= 0

  def new(n), do: %__MODULE__{n: n}
end
