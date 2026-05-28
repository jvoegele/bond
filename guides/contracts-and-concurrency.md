# Contracts in a Concurrent World

Bond's `old/1` macro snapshots a value at function entry so a postcondition
can compare the after-state to the before-state. That works cleanly when the
captured state is owned by the running process — a struct field, a process-
dictionary entry, an ETS table the process has exclusive access to. The
trickier case is state shared across processes: an `Agent`, a `GenServer`,
a shared ETS table, a database row. Another process can interleave between
the `old` snapshot and the postcondition's read of the new state, and the
comparison becomes meaningless.

This guide works through the problem with a concrete example — a counter
built on top of `Agent` — and ends with a refactoring pattern that recovers
the strong "incremented by exactly one" assertion the natural postcondition
wanted to express. The first half shows the race; the second half shows the
fix.

Here's the `Counter` module:

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

This implementation suffers from race conditions that invalidate the
correctness of the postcondition for `increment_count/1`: if a concurrent
call to `increment_count/1` is interleaved anywhere between the two calls
to `get_count/1` (in the postcondition) and the call to `Agent.update/3`,
then the postcondition will fail because the count will have increased by
more than one. (Keep in mind that `old` expressions are resolved prior to
function execution, and therefore the call to `get_count/1` in
`old(get_count(agent))` will be done before the call to `Agent.update/3`.)

The first thing we can do is weaken the assertion in the postcondition so
that it guarantees only that the count increased by some amount, not
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

## Strengthening the State module with invariants

Bond 0.13.0 added `@invariant` declarations that constrain properties of a
struct across *every* public function in its defining module — rather than a
single function at a time. For the `Counter.State` module above we can express
a structural property of the state as an invariant:

```elixir
defmodule Counter.State do
  use Bond

  defstruct [:count]

  @invariant non_negative_count: subject.count >= 0

  @post count_incremented_by_1: result.count == current_count + 1
  def increment_count(%__MODULE__{count: current_count} = state) do
    %{state | count: current_count + 1}
  end
end
```

The `non_negative_count` invariant is now checked automatically on the way
into and out of `Counter.State.increment_count/1` — and on the way into and
out of *every* other public function in `Counter.State` that takes or returns
a `%Counter.State{}`. We didn't have to repeat it as a precondition or
postcondition; declaring it once as an invariant covers the module's whole
public API.

This pattern — pure functional state struct with invariants, plus a thin
stateful wrapper — gives the strongest guarantees Bond can provide for code
that has both pure and concurrent concerns. Structure your modules this way
when you can; the strong contracts on the State struct, plus the weakened
postconditions on the Agent wrapper, together describe what's actually true.
