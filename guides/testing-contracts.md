# Testing Contracts

Contracts and tests answer the same question — *does this code behave?* — so it
is no surprise that they reinforce each other. The hard part of most tests is the
**oracle**: the code that decides whether an output is right or wrong. With Bond,
the oracle already exists. A `@pre`/`@post`/`@invariant`/`check` is a runtime
predicate that fires at every call site, so testing contracted code is less about
writing assertions and more about *driving the code* until a contract complains.

Bond gives you two complementary ways to do that:

  * **`Bond.Test`** — example-based. You make a specific call and assert that a
    contract *was* violated (or, implicitly, that it was not). This is how you test
    the contracts themselves, and how you pin down a known edge case.
  * **`Bond.PropertyTest`** — property-based. You hand Bond generators and it feeds
    random inputs through the already-instrumented code, letting the contracts be
    the oracle across inputs you would never have enumerated by hand.

## How much to test

**A contract you have never seen fail is a claim, not a check.** Every non-trivial contract is
worth a `Bond.Test` assertion proving it fires on the input it exists to reject, and every
contract stating a *law* — rather than a bound — is worth a `contract_holds/2` over inputs you
could not enumerate by hand.

For calibration, from a Phoenix application contracted with these guides: 27
`assert_precondition_violation`, 27 `assert_invariant_violation`, 12
`assert_postcondition_violation` and 22 `contract_holds`, against roughly 180 contracts. That is
about one proof for every two contracts, concentrated on the ones carrying real laws — a floor
worth beating rather than a target.

Property testing is the part most often left on the table, and `contract_holds/2` is cheap once a
generator exists: it turns an assertion you checked against four fixtures into one checked
against hundreds of inputs, using the contract you already wrote as the oracle, so there is no
second assertion to keep in step. The best candidates are pure functions whose `@post` states a
relationship — conservation, ordering, idempotence, agreement between two spellings of one input.

`invariants_hold/2` is cheaper still and the most under-used macro here: a struct module that
already has an `@invariant` needs only a list of constructors, transformers and observers to get
random operation sequences checked against it, with no generator design and no new assertions. If
a module has an invariant and no property, that is usually the least work for the most coverage
available to you.

## Which tool when

| You want to check… | Use | Module |
| --- | --- | --- |
| A specific call violates a contract | `assert_precondition_violation` and friends | `Bond.Test` |
| A specific valid call succeeds | just call it and assert the result | — |
| Contracts hold over random *valid* inputs | `contract_holds/2` | `Bond.PropertyTest` |
| …and probe the *boundaries* the `@pre` implies | `probe_contract/2` | `Bond.PropertyTest` |
| Invariants hold across random *stateful sequences* | `invariants_hold/2` | `Bond.PropertyTest` |
| A `Bond.Server` callback upholds its contracts | `contract_holds/2` on the callback | `Bond.PropertyTest` |
| A `Bond.Server` upholds its invariants across random *message sequences* | `server_invariants_hold/2` | `Bond.PropertyTest` |

A rule of thumb: reach for `Bond.Test` to test *the contracts* (the edges where they
should and shouldn't fire), and for `Bond.PropertyTest` to test *the code* (that it
honours its contracts everywhere). Most contracted modules want some of each.

## Setup

`Bond.Test` needs nothing beyond ExUnit — it ships with `bond`.

`Bond.PropertyTest` builds on
[StreamData](https://hex.pm/packages/stream_data), which is an *optional*
dependency of `bond`. Add it to your own project to enable property-based testing:

```elixir
def deps do
  [
    {:bond, "~> 1.18"},
    {:stream_data, "~> 1.0", only: [:dev, :test]}
  ]
end
```

If `stream_data` is not on the path, `use Bond.PropertyTest` raises a `CompileError`
explaining how to add it.

## Example-based testing with `Bond.Test`

`use Bond.Test` imports a macro per contract kind. Each wraps the call in an
`assert_raise` for the matching exception and returns the raised struct:

  * `assert_precondition_violation/2` → `Bond.PreconditionError`
  * `assert_postcondition_violation/2` → `Bond.PostconditionError`
  * `assert_check_violation/2` → `Bond.CheckError`
  * `assert_invariant_violation/2` → `Bond.InvariantError` (struct `@invariant`, and
    `Bond.Server` `@state_invariant` / `@transition_invariant` — pass `kind:` to be specific)

```elixir
defmodule MyApp.MathTest do
  use ExUnit.Case
  use Bond.Test

  alias MyApp.Math

  test "sqrt rejects negative input" do
    assert_precondition_violation(Math.sqrt(-1))
  end
end
```

### Targeting a specific contract

A function often has several preconditions. Pass an optional keyword of expected
fields to assert that the violation was the *particular* one you meant to trigger —
most usefully its `label`:

```elixir
# @pre numeric_x: is_number(x), non_negative_x: x >= 0
assert_precondition_violation(Math.sqrt(-1), label: :non_negative_x)
assert_precondition_violation(Math.sqrt("NaN"), label: :numeric_x)
```

Without the `label:`, the test would pass as long as *any* precondition fired — which
can mask a bug where the wrong guard is doing the rejecting. Naming the expected
clause makes the test say what it means.

### Matching fields and inspecting the failure

Field expectations may be exact values or `Regex` patterns (regexes match against the
string form of the field, such as the rendered `:expression` or the `:file`):

```elixir
assert_postcondition_violation(Math.sqrt(2, fn _ -> 10 end),
  module: MyApp.Math,
  function: {:sqrt, 2},
  expression: ~r/is_float/
)
```

Each macro returns the exception struct, so you can drill further — for instance into
the captured `:binding`, the variables in scope when the contract failed:

```elixir
error = assert_precondition_violation(Math.sqrt(-1))
assert error.binding[:x] == -1
```

### Asserting a contract is *not* violated

There is no separate "refute" helper, and none is needed: a valid call simply returns.
To assert that a contract does *not* fire for a given input, call the function and
assert on its result — if a contract were violated, the call would raise and fail the
test:

```elixir
test "sqrt accepts a non-negative input" do
  assert Math.sqrt(4.0) == 2.0
end
```

## Property-based testing with `Bond.PropertyTest`

`use Bond.PropertyTest` brings in `ExUnitProperties` and three macros. Because the
contracts are the oracle, you supply only the generators — there is no separate
model of "expected output" to maintain.

### `contract_holds/2` — one function, your generators

Pass a function capture and one generator per argument. The macro generates random
inputs, calls the function, and lets any precondition, postcondition, or `check`
violation fail the property (StreamData then shrinks to a minimal counterexample):

```elixir
defmodule MyApp.MathTest do
  use ExUnit.Case
  use Bond.PropertyTest

  contract_holds &MyApp.Math.sqrt/1, args: [StreamData.float(min: 0.0)]
end
```

Here you are responsible for generating *valid* inputs — note the `min: 0.0`, which
keeps the generator inside `sqrt`'s `@pre`. If a generated input violates the
precondition, `contract_holds/2` treats that as a failure. When you would rather
generate broadly and let Bond filter, use `probe_contract/2`.

> #### These macros go at the module level {: .warning}
>
> `contract_holds/2`, `probe_contract/2`, `invariants_hold/2` and
> `server_invariants_hold/2` **define** a property. They are not assertions you call
> inside a `test` block — put one there and Bond stops you with an error saying so.
>
> This is the opposite of the `Bond.Test` assertions above, which *are* called inside a
> `test`. The two live side by side and behave oppositely, so it is worth the glance.

### Naming a property with `:name`

Every one of these macros derives its property name from the target, so two properties
for the same function or module collide. Give at least one of them a `:name`:

```elixir
contract_holds &MyApp.Math.sqrt/1,
  args: [StreamData.float(min: 0.0)],
  name: "sqrt over all non-negative floats"

contract_holds &MyApp.Math.sqrt/1,
  args: [StreamData.float(min: 0.0, max: 1.0)],
  name: "sqrt over the unit interval"
```

Bond reports the collision at compile time and points at `:name`, rather than letting
it surface as ExUnit's `DuplicateTestError`. Worth doing even when it is not required:
a name is what the failure report shows, so distinct names are what tell you *which*
of two properties failed.

### `probe_contract/2` — one function, boundary-driven

`probe_contract/2` reads the literal comparisons in a function's `@pre` and mixes the
implied **boundaries** into your generators, so the property hits the edges — where
off-by-one postcondition bugs live — deliberately rather than by chance. Two kinds of
edge are probed:

  * **Value boundaries** from `arg <op> literal` (e.g. `amount >= 0`, `amount <= 100`)
    are injected as values straddling the literal.
  * **Size boundaries** from `length(arg) <op> literal` (and `byte_size`, `tuple_size`,
    `map_size`) cause Bond to *construct* collections/binaries of the boundary sizes from
    your generator's output — so `@pre length(items) <= 3` is probed with length-2/3/4
    lists. Bond reuses the generated elements (truncating, or padding by cycling them) so
    they still satisfy any element-level precondition. A map is only ever *shrunk* toward a
    smaller target, since new unique keys can't be synthesised safely; an undersized one is
    left for the `@pre` filter to discard.

It also uses the precondition as a **filter**: an input that violates `@pre` is
*discarded* (a generation miss, not a failure) instead of failing the property, leaving
the `@post`/`check` contracts as the oracle on the inputs that survive.

```elixir
defmodule MyApp.AccountTest do
  use ExUnit.Case
  use Bond.PropertyTest

  probe_contract &MyApp.Account.deposit/2,
    args: [account_gen(), StreamData.integer(-5..105)]
end
```

The difference from `contract_holds/2` is one of intent:

  * `contract_holds/2` — *your* generators produce only valid inputs; every input is a
    real call that must satisfy every contract.
  * `probe_contract/2` — generate broadly; Bond probes the precondition boundaries and
    discards out-of-precondition inputs, so the postcondition is the oracle.

Functions whose `@pre` has no literal comparison (or no `@pre` at all) are still
exercised — there are simply no boundary candidates to inject and nothing to filter, so
`probe_contract/2` degrades gracefully to plain generated testing. Note that boundaries are
read from the `@pre` only: a significant constant in the function *body* (the `5` in
`Enum.split(items, 5)`, say) is invisible to `probe_contract/2`, so generate around such an edge
yourself — or lift it into a `@pre` if it is genuinely part of the contract.

#### Choosing a generator `probe_contract/2` can actually drive

The commonest reason a `probe_contract/2` property fails to get off the ground is a
generator that disagrees with the precondition. Three things to know.

**Your generator must satisfy `@pre` at every generation size, not just on average.**
StreamData ramps the size up from 0, and a size-dependent generator sits at the bottom
of its range early on — `StreamData.list_of(gen, length: 4..6)` produces only length-4
lists at the opening sizes. A `@pre` that excludes 4 rejects every one of them and the
run ends with `FilterTooRestrictiveError` before the size ever grows, however healthy
the average acceptance rate looks. When the precondition constrains a size, pin it:

```elixir
# @pre five_segments: length(Path.split(key)) == 5
probe_contract &Keys.decode/1,
  args: [
    StreamData.map(
      StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1), length: 5),
      &Enum.join(&1, "/")
    )
  ]
```

**Boundaries are read from a bare parameter.** `@pre length(items) <= 3` yields size
boundaries; `@pre length(Path.split(key)) == 5` does not, because the size constrains a
computed value rather than an argument. Bond injects nothing in that case and falls back
to your generator plus the filter — which is why the generator above encodes the size
itself.

**Boundary probing pays off for inequality preconditions.** For `@pre length(items) <= 3`
the injected sizes 2 and 3 both satisfy `@pre`, so the edge is really exercised. For an
equality precondition like `@pre length(items) == 3`, the injected neighbours 2 and 4 are
exactly what `@pre` excludes — the filter discards them, and probing adds nothing beyond
what your generator already produces. Reach for `probe_contract/2` when the precondition
bounds a range; for an exact-shape precondition, `contract_holds/2` with a generator that
produces only valid inputs says the same thing more directly.

#### Pure functions probe best

`probe_contract/2` calls the function once per generated input, so a function that reaches
an external collaborator needs that collaborator stubbed for *every* iteration — `Mox.stub/3`
rather than `expect/4`. Worse, a `@post` that constrains what the collaborator returned is
then partly testing the stub rather than the function.

Prefer extracting the pure core and probing that, or injecting the collaborator so a
deterministic double can stand in. The same split makes the contract easier to state: the
pure core usually has the interesting `@pre`/`@post`, and the shell that calls out has
little to say beyond "passes its arguments along".

### `invariants_hold/2` — stateful module sequences

Where the previous two macros drive a single function, `invariants_hold/2` drives
random *sequences* of operations over a struct module, checking the module's
`@invariant`s (and any per-function contracts) across every reachable state. The
invariants are a free oracle: they hold at every operation's entry and exit, so there
is no need to write an explicit model of expected behaviour.

```elixir
defmodule MyApp.BoundedStackTest do
  use ExUnit.Case
  use Bond.PropertyTest

  invariants_hold BoundedStack,
    constructors: [{:new, [StreamData.integer(1..100)]}],
    transformers: [{:push, [StreamData.term()]}, {:pop, []}],
    observers:    [{:size, []}, {:peek, []}]
end
```

Each spec is a list of `{fun_name, [arg_generators]}` tuples. A **constructor** produces
the initial struct; a **transformer** takes the current struct as its first argument and
returns the next one (`%Mod{}` or `{:ok, %Mod{}}`); an **observer** takes the struct but
does not advance the state. A transformer returning `{:error, _}` ends the sequence
cleanly (an operation that refuses is not a contract violation); any other return shape
raises an `ArgumentError`.

## Testing `Bond.Server`s

A `Bond.Server` adds `@state_invariant` and `@transition_invariant`, which Bond weaves
*into* the server's state-transition callbacks (see
[Contracts in a Concurrent World](contracts-and-concurrency.md)). That weaving is what
makes them testable with the tools above: because the checks are compiled into the
callback itself, you do not need a running process to exercise them — you can call the
callback as a plain function and the invariants still fire.

### Driving callbacks directly with `contract_holds/2`

A single function capture of a callback exercises a surprising amount. Take the `Counter`
from the concurrency guide (`@state_invariant non_negative: state.count >= 0`,
`@transition_invariant monotonic: new_state.count >= old_state.count`):

```elixir
defmodule CounterTest do
  use ExUnit.Case
  use Bond.PropertyTest

  contract_holds &Counter.handle_call/3,
    args: [
      StreamData.constant(:inc),
      StreamData.constant({self(), make_ref()}),                 # `from` — unused by the body
      StreamData.map(StreamData.non_negative_integer(), &%{count: &1})
    ]
end
```

One property checks four things at once. On every generated call, Bond verifies:

  * the callback's own `@pre`/`@post`/`check` contracts;
  * the **`@state_invariant`** on the state the callback **returns**;
  * the **`@transition_invariant`** relating the **incoming** state (the callback's last
    argument) to the returned one — the wrapper reads `old_state` straight from that
    argument, so a direct call has everything it needs;
  * and, implicitly, that the callback returns a well-formed `{:reply, _, state}` /
    `{:noreply, state}` shape (a mismatch raises before any contract runs).

The same shape works for `handle_cast/2`, `handle_info/2`, and `handle_continue/2`. It is
also how a *buggy* operation gets caught: a `contract_holds &Counter.handle_cast/2` over
the `:dec` cast fails and shrinks to `%{count: 0}`, because decrementing from zero
violates both `non_negative` (the produced state) and `monotonic` (the transition).

### Your state generator must produce *reachable* states

There is one subtlety unique to servers. An invariant guards the state a callback
*produces*, not the one passed *into* it — the inductive model described in the
[concurrency guide](contracts-and-concurrency.md). The callback therefore *assumes* its
incoming state already satisfies the invariant, so your generator must produce only
states the server could actually be in. Feeding `%{count: -1}` to `handle_call(:inc, …)`
would report a `@state_invariant` failure on the *output* (`%{count: 0}` is fine, but
`%{count: -3}` → `%{count: -2}` is not) — a spurious counterexample for a state the
server can never reach. Constrain the generator (here, `non_negative_integer/0`)
accordingly.

This is also the honest limitation of the direct-callback approach: it explores the
states *you generate*, not the server's true *reachable* set. For a server whose reachable
states are subtle, see "Covering the reachable state space" below.

### Callbacks with side effects

If a callback calls out to an external service, stub it in `setup` so the property can
drive it freely. With [Mox](https://hex.pm/packages/mox), a `stub/3` allows unlimited
calls and keeps the contracts — not the collaborator — as the thing under test:

```elixir
describe "handle_info(:flush, _) upholds its contracts" do
  setup do
    stub(MyApp.HTTPClientMock, :post, fn _payload -> {:ok, :sent} end)
    :ok
  end

  contract_holds &MyApp.Uploader.handle_info/2,
    args: [StreamData.constant(:flush), uploader_state_gen()]
end
```

Pair it with a second `describe` whose stub returns an error tuple to drive the failure
branch — the postconditions should hold on both. Tag the failure block
`@describetag capture_log: true` if the error path logs.

### Asserting a specific invariant violation

To pin down that a *particular* transition is rejected, use `Bond.Test` and pass `kind:`
to distinguish the two invariant flavours (both raise `Bond.InvariantError`):

```elixir
use Bond.Test

test ":dec below zero violates the state invariant" do
  assert_invariant_violation(Counter.handle_cast(:dec, %{count: 0}),
    kind: :state_invariant,
    label: :non_negative
  )
end
```

Because invariants fire inside the woven callback, this works on a direct call just as it
would when driving a live server.

### Covering the reachable state space with `server_invariants_hold/2`

`server_invariants_hold/2` is `invariants_hold/2`'s process-world sibling: it generates
random message sequences, drives the server through them, and lets its
`@state_invariant`/`@transition_invariant` (plus each callback's `@pre`/`@post`) be the
oracle across the **reachable** state space — no hand-written state generator to drift out
of sync with the server.

```elixir
defmodule BankServerTest do
  use ExUnit.Case
  use Bond.PropertyTest

  server_invariants_hold Bank,
    init: StreamData.integer(0..100),
    messages: [
      call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
      cast: [{:deposit, [StreamData.positive_integer()]}],
      info: [{:tick, []}]
    ]
end
```

Each iteration generates an initial `init/1` argument and a random sequence, threads the
server through it, and fails the property on any contract violation — `StreamData` shrinks
to a minimal `(init, sequence)` counterexample. A message spec `{name, [gens]}` becomes the
bare atom `name` when it takes no arguments (`{:tick, []}` → `:tick`) or the tuple
`{name, …}` otherwise (`{:withdraw, [gen]}` → `{:withdraw, amount}`).

**Two execution modes** (`:mode` option):

  * **`:callbacks`** (the default) — seeds state from `init/1` and invokes the callbacks
    directly, threading each returned state into the next. Deterministic, fast, and quiet; it
    follows a genuinely reachable trajectory (real `init`, real callback returns) but does not
    exercise real dispatch, mailbox ordering, or timers. The right default for CI.
  * **`:process`** — starts a real server and drives it with `GenServer.call`/`cast` and
    `send/2`. Highest fidelity, but a violation crashes the server, so expect
    `GenServer terminating` log reports (add `@moduletag :capture_log`) and slower runs. Reach
    for it when real dispatch or timer behaviour is part of what you're testing.

If your server delegates to a pure state module with its own `@invariant`s (the pattern the
concurrency guide recommends), you can also point the struct runner `invariants_hold/2` at
that core and keep the server a thin, separately tested shell.

> #### Side effects and reachable-state coverage {: .info}
>
> Two things to keep in mind when a callback isn't pure:
>
>   * **Mocked collaborators.** In `:callbacks` mode the callbacks run in the test process, so a
>     private-mode `Mox.stub`/`expect` in a `setup` (the usual `async: true` pattern) is in scope.
>     In `:process` mode the server runs in a spawned process that won't see those expectations —
>     use `Mox.set_mox_global` with `async: false`, or `Mox.allow/3` the server's pid. Preferring
>     `:callbacks` sidesteps this entirely.
>   * **State gated behind a collaborator's reply is only reachable via that reply.** The sequence
>     explores states reachable *through messages*, holding the stubbed collaborator fixed — so a
>     branch that only runs when, say, an API call *fails* is not reached by a success stub, no
>     matter the sequence. Cover each such path with its own run under the appropriate stub, exactly
>     as you would split example-based tests by outcome.

## Contract coverage — which assertions have you seen fail?

The tools above prove a contract *can* fire. `Bond.Coverage` answers the complementary
question across a whole suite: **which assertions ran but were never once false?** An
assertion checked hundreds of times that has never failed is a candidate for vacuity — the
runtime counterpart to the compile-time [assertion linter](writing-sound-assertions.md).

It is a *prompt*, not a verdict. A correct assertion over correct code also never fails, so
`⚠ never failed` is a question with four answers, and only one of them is "delete it":

| Why it cannot fail | What to do |
|---|---|
| It transcribes *how* the body works | Restate it as *what* the function promises |
| The body guards the property twice **by accident** | **Delete the redundant guard**, keep the contract |
| Two guards are **independently sufficient** by design | Keep both — and mutate them *together* |
| It is a true law of a pure function | Keep it — prove it by **mutation**, not by a test |

The two middle rows look identical from the table and want opposite treatment. An accidental
double-guard is one check too many. Defence in depth — an application-level scope *and* row-level
security underneath it — is falsifiable only by removing **both**, which is precisely the refactor
the contract above them exists to notice. See
[Running a mutation](#running-a-mutation) below.

The last is the common case for a specification and is not a defect: a pure function's
postconditions hold over every input the application ever sees, which is the point of writing
them. Where no input can falsify one, break the implementation deliberately, confirm the
assertion fires, and restore it — that is what distinguishes unbreakable-by-correct-code from
unbreakable-because-vacuous.

Coverage is **compile-time opt-in**, so a build that does not enable it is byte-for-byte
unchanged and pays nothing. Enable it for the test environment and install the end-of-suite
reporter:

```elixir
# config/test.exs
config :bond, coverage: true
```

```elixir
# test/test_helper.exs
ExUnit.start()
Bond.Coverage.install_reporter()
```

Now `mix test` prints a table after the suite:

```
Bond contract coverage
  MyApp.CacheInvalidator
    handle_info/2
      @state_invariant :non_negative        checked  1184×  failed     3×  ✓
      @post :keeps_input                     checked   642×  failed     0×  ⚠ never failed
```

A `⚠` row is a candidate to interrogate with `Bond.Test` (prove it can fail) — the "prove
every assertion can fail" habit from the [Writing Sound Assertions](writing-sound-assertions.md)
guide. `Bond.Coverage.entries/0` and `report/0` are also readable directly if you want to
inspect coverage in a test or write it to a file.

> #### Server invariants deserve the extra attention {: .warning}
>
> A violated `@state_invariant` raises *inside* the server. Its supervisor restarts it, and a
> caller that was not waiting on that exact reply absorbs nothing — so the suite can report all
> green while an invariant is failing on every message. That makes the coverage row the signal
> that a failing test would normally be, and it makes `⚠ never failed` on a state invariant worth
> interrogating rather than skimming past: no caller can put a process into a bad state by hand,
> so vacuity here is the hardest kind to notice by reading.

Keep expectations modest: in a mature codebase **most** rows will read `⚠ never failed`,
because most postconditions and invariants over correct code genuinely never fail — that is
what a green suite means. This is a spot-check to skim occasionally for a contract that looks
suspiciously safe, not a to-do list to drive to zero.

## Running a mutation

Mutation is the proof for the last row of that table, and the only thing that separates
unbreakable-by-correct-code from unbreakable-because-vacuous: break the implementation
deliberately, confirm the assertion fires, restore. One mutation at a time, reverted before the
next.

It is also easy to do in a way that reports a confident wrong answer. Five traps, each of which
has cost real time in a real audit — the last of them deleted a correct contract.

### Aim the mutation at the function the contract is on

**A surviving mutation is evidence about the mutation until you have checked that it is evidence
about the contract.** The aim misses in both directions.

*Too far out.* `ordered_best_first` is a `@post` on `rank/3`. Mutating `match/3` to return
`List.last/1` leaves `rank/3`'s own result correctly ordered: the contract holds because it is
still true there, and the mutation tested nothing.

*Too far in.* A `@post` on `Client.playlist_item_references/3` promises that every returned
reference has both halves usable. Mutate the mapper it delegates to and the *mapper's* own
postcondition raises first, one call inward — the outer contract never sees the bad value, and
looks unfalsifiable. It is not. Corrupt the way the client assembles pages instead: the mapper
stays satisfied on every individual page, and the outer contract fires at once.

That second case invites a conclusion that sounds right and is wrong — *the collaborator already
guarantees this, so the outer contract is redundant*:

> **A function whose body delegates to a collaborator that already guarantees a property still
> owes that property to its own caller.**

The delegation is an implementation fact, and a refactor can retire that collaborator tomorrow.
The guarantee is the specification: it renders into *this* function's generated docs, and its
callers read it there without any reason to know the collaborator exists. It is the same
distinction as `full?` — the delegation is prescriptive, the assertion descriptive.

### Run a null control first

The coverage table prints every label on every run, so a harness that greps the output for a
label matches whether or not anything failed. Written the obvious way, it reports a hit for every
mutation you try, including the ones that changed nothing.

Two things actually indicate a violation: `label: :the_name` inside a raised `Bond.*Error`, or a
coverage row for that label whose **failed** count is non-zero.

```elixir
defp fired?(output, label) do
  String.contains?(output, "label: :#{label}") or
    ~r/:#{label}\s+checked\s+[\d,]+×\s+failed\s+([\d,]+)×/
    |> Regex.run(output)
    |> case do
      [_, count] -> String.replace(count, ",", "") != "0"
      nil -> false
    end
end
```

Then **run the harness once with no mutation applied**. If anything reports a hit, what you have
found is a broken detector, not a broken contract.

### Give each assertion a mutation its neighbours survive

Assertions on one function fail fast in execution order, so a mutation that breaks the first
raises before the second is ever evaluated — and the second appears unfalsifiable under every
mutation you try. The
[layered-contract ordering](#patterns-and-gotchas) noted below for tests is a mutation-testing
trap as well, and a quieter one.

Real case: `from_the_archive` and `names_the_album_asked_about`, both on a cover-art lookup.
Returning a redirect target fires the first and pre-empts the second. Proving the second needs a
mutation that keeps the host intact and changes the album — then it fires immediately.

Across *function* boundaries the same pre-emption is a genuine signal rather than a trap: a law
restated at two altitudes, where the inner assertion always raises first, is redundant, and the
outer one should go. The coverage table cannot tell the two readings apart. What separates them
is **whether a bug exists that the inner assertion cannot see** — a paging bug is invisible to
the mapper in the client example above, so that outer contract earns its place; where no such bug
exists, it does not.

### Two independently sufficient guards need mutating together

Where a property is enforced twice *by design*, no single mutation can falsify a contract above
it, and the row reads `⚠ never failed` for a contract that is doing real work.

Measured case: an application-level `where user_id == ^user_id` and Postgres row-level security
underneath it. Drop the `where` and RLS still filters; drop the RLS scope and the `where` still
does. The scoping postcondition fires only when **both** go — which is the only way the law is
genuinely breakable, and exactly the refactor you want something to notice.

This is the row of the table above that is easiest to misread, and reading it wrong deletes the
contract that would have caught the refactor. Accidental double-guarding means remove one guard
and keep the contract; defence in depth means keep both guards and mutate them together.

### Mutate toward wrong values, not toward no values

A `forall` over an empty enumerable is vacuously true, so any mutation that makes a collection
*absent* rather than *wrong* leaves the contract satisfied and tells you nothing.

Real case: a scoping law over the connections a page lists. The obvious mutation — read them for
a random user id — returns `[]`, and the law holds. Proving it required a mutation that returned
*another user's* rows, which in turn required a second user in the fixtures. When the only
realistic mutation empties the collection, the missing piece is usually a fixture rather than a
contract.

### When a mutation survives, suspect the fixtures first

Once the four traps above are ruled out, a surviving mutation more often indicts the *tests* than
the contract. Three real cases where the contract turned out to be fine:

  * Every fixture happened to give every artist a name, so a filter's postcondition never saw the
    shape it guards.
  * Every test refreshed an already-clean connection, so "clears failure state" looked identical
    to clearing nothing.
  * A test named "a gap does not shift positions" passed under a rewrite that counted by index —
    because on the captured album, track number happened to equal list position for all fourteen
    items. A multi-volume release, where disc 2 restarts at track 1, is the discriminating case.

A real fixture is not automatically a *discriminating* one, and when a test's name states a
distinction, it is worth checking that the data actually exhibits it.

## Patterns and gotchas

  * **A shrunk counterexample may render a list of small integers as a charlist.**
    A sequence failure reported as

    ```text
    Generated: {{:constructor, :new, []}, [{:transformer, :apply_discount, ~c"e"}]}
    ```

    is showing you `[101]` — the argument list for that operation, which Elixir's
    inspect renders as `~c"e"` because every element happens to be a printable
    character code. Nothing is wrong with the counterexample; the rendering comes from
    ExUnitProperties rather than from Bond, so Bond cannot change it. Read it as a list
    of integers.

  * **Choosing `contract_holds` vs `probe_contract`.** If writing a generator that
    produces only valid inputs is easy (`StreamData.float(min: 0.0)`), `contract_holds/2`
    is the most direct tool. If the precondition is interesting at its edges, or you want
    to generate broadly without hand-constraining every generator, `probe_contract/2`
    earns its keep.

  * **`probe_contract/2` and over-restrictive preconditions.** Because it filters by
    `@pre`, a precondition that rejects most generated inputs will raise
    `Bond.PropertyTest.FilterTooRestrictiveError` — a Bond-shaped error that names the
    function and points at the fix, rather than StreamData's generic "too many filtered"
    message. Narrow your base generators toward the valid range (as with
    `StreamData.integer(-5..105)` above), or use `StreamData.bind/2` for relational
    preconditions like `amount <= account.balance` (which boundary injection can't probe
    for you), so valid inputs are produced often enough.

  * **Destructuring heads.** If a single-clause function destructures an argument in its
    head (e.g. `def f(%Account{} = a, n)`), the generator for that argument must produce
    shape-matching values — exactly as the function itself requires.

  * **Layered contracts.** When contracts are layered (inheritance, applied named
    contracts, refinement), violations fail-fast in execution order. If a test asserts on
    *which* contract fired, target it by `label` (and, for inherited contracts,
    `source_behaviour`) rather than relying on ordering.

## See also

  * `Bond.Test` and `Bond.PropertyTest` — the full reference for every macro and option.
  * [Reusable Contracts](reusable-contracts.md) — named contracts, which these helpers
    test exactly like any other `@pre`/`@post`.
  * [Contracts in a Concurrent World](contracts-and-concurrency.md) — testing `old/1`-based
    postconditions over shared state.
