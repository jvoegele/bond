# Contracts in a Concurrent World

The `Bond` moduledocs touched on the pitfalls of defining contracts for
stateful concurrent processes. This guide will provide a more in-depth
discussion of the problem and offer a solution for devising contracts in such
a context that does not compromise the strength of the assertions in the
contracts.

Let's revisit the example of a stateful `Counter` module in the form it was
originally presented, this time with all of the `Agent` details provided:

```elixir
defmodule Counter do
  use Agent
  use Bond

  def start_link(initial_count) do
    Agent.start_link(fn -> initial_count end)
  end

  def get_count(agent) do
    Agent.get(agent, & &1)
  end

  @post count_incremented_by_1: get_count(agent) == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
end
```

As we saw, this implementation of the `Counter` agent suffers from race
conditions that invalidate the correctness of the postcondition for
`increment_count/1`: if a concurrent call to `increment_count/1` is interleaved
anywhere between the two calls to `get_count/1` (in the postcondition) and the
call to `Agent.update/3`, then the postcondition will fail because the count
will have increased by more than one. (Keep in mind that `old` expressions are
resolved prior to function execution, and therefore the call to `get_count/1`
in `old(get_count(agent))` will be done before the call to `Agent.update/3`.)

Our solution to this problem was to weaken the assertion in the postcondition
so that it guaranteed only that the count increased by some amount, not
necessarily by exactly one:

```elixir
  @post count_increased: get_count(agent) > old(get_count(agent))
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
```

As noted, this is the best we can do with the given implementation of the
`Counter` that uses an `Agent` to store the counter state. Since agents are
stateful, concurrent processes that do not offer a locking mechanism or
isolated transactions, concurrent state updates between evaluation of
preconditions, postconditions, and the function body are always a possibility.
Given this possibility, contracts can only make weak guarantees about the
observable effects of concurrent state updates, such as `count_increased` above.

However, we can do better if we refactor the `Counter` module to separate the
purely functional parts from the stateful and concurrent parts of the code.
This oft-given advice is useful not only in the context of contract
programming, but also for improving the testability and design of the code in
general.

Let's see how we can do this for our `Counter` module, and how it strengthens
the assertions that we can express:

```elixir
defmodule Counter do
  use Agent
  use Bond

  defmodule State do
    use Bond

    defstruct [:count]

    @post count_incremented_by_1: result.count == current_count + 1
    def increment_count(%__MODULE__{count: current_count} = state) do
      %{state | count: current_count + 1}
    end
  end

  def start_link(initial_count) when is_integer(initial_count) do
    Agent.start_link(fn -> %State{count: initial_count} end)
  end

  def get_count(counter) do
    Agent.get(counter, & &1.count)
  end

  @post count_increased: get_count(counter) > old(get_count(counter))
  def increment_count(counter) do
    Agent.update(counter, &State.increment_count/1)
  end
end
```

We've added a nested `State` module to our existing `Counter` module. It
defines a struct with a single `:count` field, and contains one pure function,
namely `increment_count/1`. (This is for demonstration purposes only.
In a more realistic scenario, the `Counter.State` module would exist
independently of the `Counter` module and be given a name appropriate to its
role in the problem domain, and would likely have more than just one field
in the struct.)

The `Counter` module has been updated to use an instance of this struct as the
agent state, and `Counter.increment_count/1` uses
`Counter.State.increment_count/1` to update the state in a purely functional
way.

Although the `count_increased` assertion is still the strongest we can provide
for `Counter.increment_count/1`, the stronger `count_incremented_by_1`
assertion is now valid for `Counter.State.increment_count/1`, because it is a
pure function! Also notice that we didn't even need to use an `old` expression
in `count_incremented_by_1` since that assertion is comparing the "old" value
of the counter from the function argument to the "new" or "current" value of
the counter in the function `result`.
