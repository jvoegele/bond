defprotocol BondTest.Counted do
  @moduledoc internal: true
  @moduledoc """
  A protocol-contract fixture compiled to an on-disk beam so `Protocol.consolidate/2` can read
  its definitions. Used by the consolidation test in `Bond.ProtocolTest`, which proves the
  dispatch wrapper survives consolidation (the #14 spike established the mechanism; this guards
  it as a regression test on real artifacts).
  """

  use Bond.Protocol

  @post non_negative: result >= 0
  @spec count(t) :: integer()
  def count(data)
end

defmodule BondTest.Counted.Bag do
  @moduledoc internal: true
  defstruct contents: []
end

defmodule BondTest.Counted.Broken do
  @moduledoc internal: true
  defstruct []
end

defimpl BondTest.Counted, for: BondTest.Counted.Bag do
  def count(%BondTest.Counted.Bag{contents: contents}), do: length(contents)
end

defimpl BondTest.Counted, for: BondTest.Counted.Broken do
  def count(%BondTest.Counted.Broken{}), do: -1
end
