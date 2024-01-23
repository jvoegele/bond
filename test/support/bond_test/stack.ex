defmodule BondTest.Stack do
  @moduledoc """
  Stack module for testing Bond contracts.

  This is an example of a "demanding" stack, as opposed to a "tolerant" stack, which is useful
  for demonstrating contracts but is not the typical Elixir style.
  """

  use Agent
  use Bond

  defstruct [:stack, :capacity, :size]

  @opaque t :: %__MODULE__{
            stack: list(),
            capacity: pos_integer(),
            size: non_neg_integer()
          }

  @opaque handle :: pid()

  @type elem :: any()

  @pre positive_capacity: capacity > 0
  @post initial_state: empty?(result)
  @spec new(capacity :: pos_integer()) :: handle()
  def new(capacity) when is_integer(capacity) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %__MODULE__{
          stack: [],
          size: 0,
          capacity: capacity
        }
      end)

    pid
  end

  @post is_integer(result) and result >= 0
  @spec size(handle()) :: non_neg_integer()
  def size(stack) do
    Agent.get(stack, & &1.size)
  end

  @post is_integer(result) and result > 0
  @spec capacity(handle()) :: pos_integer()
  def capacity(stack) do
    Agent.get(stack, & &1.capacity)
  end

  @post definition: result == (size(stack) == 0)
  @spec empty?(handle()) :: boolean()
  def empty?(stack) do
    Agent.get(stack, &(&1.size == 0))
  end

  @post definition: result == (size(stack) == capacity(stack))
  @spec full?(handle()) :: boolean()
  def full?(stack) do
    Agent.get(stack, &(&1.size == &1.capacity))
  end

  @pre not full?(stack)
  @post not empty?(stack)
  @post top(stack) == elem
  # @post "size increased by one": size(stack) == old(size(stack)) + 1
  @spec push(handle(), elem()) :: :ok
  def push(stack, elem) do
    Agent.update(stack, fn %{stack: stack, size: size} = state ->
      %{state | stack: [elem | stack], size: size + 1}
    end)
  end

  @pre not empty?(stack)
  @post not empty?(stack)
  @spec top(handle()) :: elem()
  def top(stack) do
    Agent.get(stack, &List.first(&1.stack))
  end

  @pre not empty?(stack)
  @post not full?(stack)
  @spec pop(handle()) :: elem()
  def pop(stack) do
    Agent.get_and_update(stack, fn %{stack: stack, size: size} = state ->
      [result | rest] = stack

      {
        result,
        %{state | stack: rest, size: size - 1}
      }
    end)
  end
end
