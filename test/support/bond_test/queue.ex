defmodule BondTest.Queue do
  @moduledoc """
  Wrapper around Erlang's :queue module for testing Bond contracts.
  """

  use Bond

  @doc """
  Returns an empty queue.
  """
  @post empty?(result)
  def new, do: :queue.new()

  @doc """
  Tests if `queue` is empty and returns `true` if so, otherwise `false`.
  """
  @post result == (count(queue) == 0)
  def empty?(queue), do: :queue.is_empty(queue)

  @post result >= 0
  @post empty?(queue) ~> (result == 0)
  def count(queue), do: :queue.len(queue)
end
