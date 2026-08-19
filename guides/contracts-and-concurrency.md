# Contracts in a Concurrent World

Bond's `old/1` macro snapshots a value at function entry so a postcondition
can compare the after-state to the before-state. That works cleanly when the
captured state is owned by the running process — a struct field, a process-
dictionary entry, an ETS table the process has exclusive access to. The
trickier case is state shared across processes: an `Agent`, a `GenServer`,
a shared ETS table, a database row. Another process can interleave between
the `old` snapshot and the postcondition's read of the new state, and the
comparison becomes meaningless.

The rest of this guide works the problem through a counter built on `Agent`:
first the race, then the refactoring that recovers the strong assertion the
obvious postcondition was reaching for.

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

That postcondition is wrong, and not because the function is. `old` expressions
resolve *before* the body runs, so evaluating this contract means three separate
trips to the agent: the `old(get_count(agent))` snapshot, then
`Agent.update/3`, then the `get_count(agent)` read in the postcondition. A
concurrent `increment_count/1` interleaving at any point between them pushes the
count up by more than one, and the assertion fails on code that did exactly what
it was asked to.

That is the worst failure mode a contract can have — it accuses correct code, so
it teaches you to distrust the contract rather than the program. The honest move
is to assert only what the implementation can actually guarantee: that the count
went up.

```elixir
  @post count_increased: get_count(agent) > old(get_count(agent))
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
```

`count_increased` survives interleaving, because "went up" stays true however
many other processes also incremented. It is also much less than the function
actually does, and that gap is the cost of the design: an `Agent` offers neither
locking nor isolated transactions, so an update can always land between a
contract's reads. While the state lives there, weak guarantees are the only
honest ones.

The gap closes by moving the interesting part somewhere a contract can speak
precisely — separating the pure transformation from the process that stores it.
The advice is not specific to contracts; it improves testability and design
generally. What contracts add is a way to *see* the payoff, because the
assertions you can write get stronger the moment the logic stops being shared:

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

The agent now holds a `State` struct, and `Counter.increment_count/1` delegates
the actual arithmetic to the pure `Counter.State.increment_count/1`. (The nested
module keeps the example short. In real code the state module would stand on its
own, named for its role in the domain, with more than one field.)

The wrapper's contract is unchanged — `count_increased` is still the strongest
thing `Counter.increment_count/1` can promise, because it still talks to a shared
`Agent`. What changed is that the interesting claim now has somewhere to live:
`count_incremented_by_1` is exactly true of `Counter.State.increment_count/1`,
because that function is pure. Nothing can interleave with a value.

Notice it no longer needs `old/1` either. The "before" state arrived as an
argument and the "after" state is the `result`, so both are in scope at once —
which is the general shape of the thing. `old/1` exists to reach outside the
function for a before-state; a function that takes its input and returns its
output has no outside to reach into.

## Strengthening the State module with invariants

An `@invariant` constrains a property of a struct across *every* public function
in its defining module, rather than one function at a time. For the
`Counter.State` module above we can express a structural property of the state
as an invariant:

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

`non_negative_count` is now checked on the way into and out of
`Counter.State.increment_count/1`, and of *every* other public function in
`Counter.State` that takes or returns a `%Counter.State{}` — including the ones
added later. It never had to be repeated as a precondition or postcondition;
declaring it once covers the module's whole public API.

This is the shape to reach for whenever code has both pure and concurrent
concerns: a state struct carrying the real contracts, wrapped by a thin stateful
shell carrying weak ones. Neither half is the whole truth on its own. Together
they say what is actually the case — that the transformation is exact, and that
observing it through a shared process is not.

## Process state invariants with `Bond.Server`

The race that opened this guide comes from *sharing*: an `Agent`'s state is read
and written by many processes, so an `old` snapshot and the later read can be
torn apart by an interleaving update. A `GenServer` is the opposite case. It
processes one message at a time, and its state is touched only from inside the
server process. There is no interleaving to defend against — which makes it the
natural home for the strongest stateful contracts Bond offers.

`Bond.Server` adds two module-wide annotations: `@state_invariant`, a property of
the state itself, and `@transition_invariant`, a relation between the state
before a transition and the state after. Because the checks run *inside the
server process, on its own sequentially-processed state*, they are race-free by
construction.

The [Invariants](invariants.md#stateful-contracts-for-processes) guide is the
reference for both — the `Counter` example, which callbacks each one fires
after, the bindings, and how they configure. This section is about something
that guide doesn't cover: *why* they can promise what a shared-state contract
cannot.

> #### Invariants guard *produced* states, not *incoming* ones {: .info}
>
> The check runs on the state a callback **returns**, not on the state passed
> *into* it. This is the standard inductive model: `init/1` establishes a state
> that satisfies the invariant, and every transition is checked to preserve it,
> so by induction every reachable state is valid — re-checking on entry would be
> redundant. The practical consequence shows up in tests: if you call a callback
> *directly* with a hand-built state that violates the invariant, Bond does **not**
> reject it on entry — the callback body runs first (and may well crash on the
> malformed state before any contract fires). To assert that a *bad input state*
> is caught, drive the server through a transition that would *produce* it, rather
> than feeding the bad state straight into a callback.

### What serialization buys you

A transition invariant constrains every *change*, where a struct `@invariant`
constrains every *value*. (In Design by Contract terms it is a *history
constraint*, in the sense of Liskov & Wing.) It has no struct-level analog, and
that is not an accident: relating a before-state to an after-state only means
something if nothing can intervene between them.

"The counter never decreases" is exactly the property the racy `Agent` counter at
the start of this guide could *not* soundly assert. There, a concurrent update
could slip between the `old` snapshot and the comparison, so the assertion would
fail on perfectly correct code — a contract that cries wolf is worse than none.
Inside a `GenServer`, transitions are serialized, so the same sentence becomes
meaningful: a violation means the *server* is wrong, not that two callers raced.

That is the first half of this guide arrived at from the other direction. There,
we weakened `count_incremented_by_1` to `count_increased`, because that was all a
shared `Agent` could honestly promise. Here the concurrency model is strong
enough that nothing has to be given up — the strongest form of the assertion is
also the true one.

### How this relates to the State-struct pattern

`@state_invariant` is *complementary* to the pure-State-struct-plus-`@invariant`
pattern above, not a replacement for it. Two differences are worth keeping in
mind:

  * **It catches inline mutation.** A struct `@invariant` only fires when the
    struct flows through a public function *of its own module*. A `GenServer`
    callback that mutates state inline — `{:noreply, %{state | count: ...}}`,
    the common style — never routes through such a function, so a struct
    invariant would not see it. `@state_invariant` wraps the callbacks
    themselves, so it does.

  * **It does not replace the pure core.** If your state is a struct with its
    own `@invariant`s and pure transition functions, keep them: those contracts
    are checked wherever the struct is used, including in tests and outside the
    server. Use `@state_invariant` for properties of the *server's* state as a
    whole, and as a safety net over callbacks that change state directly.

To drive either flavour from a property test — including
`server_invariants_hold/2`, which explores the server's *reachable* states rather
than the ones you thought to generate — see
[Testing Contracts](testing-contracts.md#testing-bond-servers).
