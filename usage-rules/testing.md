# Bond: testing contracted code

Contracts are the **oracle** — the part of a test that decides whether an output is right. So
testing contracted code is less about writing assertions and more about driving the code until a
contract complains.

Two tools, and they behave oppositely, so keep them straight:

| | Called | Purpose |
| --- | --- | --- |
| `Bond.Test` | **inside** a `test` block | Test *the contracts* — prove they fire on the input they should reject |
| `Bond.PropertyTest` | at **module level**, never inside a `test` | Test *the code* — prove it honours its contracts across inputs you'd never enumerate |

Putting a `contract_holds/2` inside a `test` block is an error, and Bond says so.

## Proving a contract fires

```elixir
defmodule MyApp.AccountTest do
  use ExUnit.Case
  use Bond.Test

  test "withdrawing more than the balance is rejected" do
    account = %Account{owner: "ana", balance: 20}

    assert_precondition_violation(Account.withdraw(account, 50),
      label: :sufficient_funds
    )
  end
end
```

**Always pass `label:`.** Without it the test passes as long as *some* precondition fired, which
stays green if a different clause starts rejecting the call for an unrelated reason.

One macro per kind: `assert_precondition_violation/2`, `assert_postcondition_violation/2`,
`assert_check_violation/2`, `assert_invariant_violation/2` (pass `kind:` to distinguish a struct
`@invariant` from a `Bond.Server` `:state_invariant` / `:transition_invariant`). Each returns the
exception struct, so you can drill into `:binding`. Field expectations may be exact values or
`Regex`.

There is no "refute" helper and none is needed — a valid call simply returns, and a violation
would raise and fail the test.

**Where a guard does the work, assert `FunctionClauseError` instead.** That is what actually
fires. Use `assert_precondition_violation` for semantic constraints only a contract can express.

## Property testing

Add `{:stream_data, "~> 1.0", only: [:dev, :test]}`. Three module-level macros:

```elixir
defmodule MyApp.MathTest do
  use ExUnit.Case
  use Bond.PropertyTest

  # your generators must produce only VALID inputs — a @pre violation fails the property
  contract_holds &MyApp.Math.sqrt/1,
    args: [StreamData.float(min: 0.0)],
    name: "sqrt over all non-negative floats"

  # generate broadly: @pre becomes a FILTER, and its literal bounds are probed
  probe_contract &MyApp.Account.deposit/2,
    args: [account_gen(), StreamData.integer(-5..105)]

  # random sequences over a struct module's @invariant
  invariants_hold BoundedStack,
    constructors: [{:new, [StreamData.integer(1..100)]}],
    transformers: [{:push, [StreamData.term()]}, {:pop, []}],
    observers:    [{:size, []}]

  # random MESSAGE sequences against a Bond.Server's reachable states
  server_invariants_hold Bank,
    init: StreamData.integer(0..100),
    messages: [
      call: [{:withdraw, [StreamData.positive_integer()]}, {:balance, []}],
      cast: [{:deposit, [StreamData.positive_integer()]}],
      info: [{:tick, []}]
    ]
end
```

**Pass `:name`** whenever two properties target the same function or module — the name is
derived from the target, so they collide otherwise. Bond reports the collision at compile time
rather than letting it surface as ExUnit's `DuplicateTestError`. Distinct names are also what the
failure report shows.

### Choosing between `contract_holds` and `probe_contract`

  * `contract_holds/2` — you guarantee validity. Most direct when a valid generator is easy
    (`StreamData.float(min: 0.0)`).
  * `probe_contract/2` — Bond reads literal comparisons out of the `@pre`, injects values
    straddling them, and **discards** inputs that violate `@pre` (a generation miss, not a
    failure), leaving `@post` as the oracle.

`probe_contract/2` earns its keep when a precondition **bounds a range**. For an *equality*
precondition (`length(items) == 3`) the injected neighbours 2 and 4 are exactly what the filter
discards, so probing adds nothing. Boundaries are read from a **bare parameter** only —
`@pre length(Path.split(key)) == 5` yields none, because the size constrains a computed value.

Your generator must satisfy `@pre` **at every generation size, not just on average**. StreamData
ramps size up from 0, so `list_of(gen, length: 4..6)` produces only length-4 lists early on; a
`@pre` excluding 4 rejects every one and the run dies with
`Bond.PropertyTest.FilterTooRestrictiveError` before the size ever grows. Pin the size in the
generator. For relational preconditions (`amount <= account.balance`), use `StreamData.bind/2` —
boundary injection cannot probe those.

**Pure functions probe best.** A function that reaches a collaborator needs it stubbed for
*every* iteration (`Mox.stub/3`, not `expect/4`), and a `@post` constraining what the
collaborator returned is partly testing the stub. Extract the pure core and probe that.

### Two rules about generators, learned the hard way

**Measure that the interesting branch is reached.** A property that passes on its first run has
proven nothing until you check it exercised anything. Two real cases: a mapper property generated
`data` and `included` with independent random ids that never collided — **0 of 500 documents
produced a single track**, and every property passed while the entire resolution path went
unexercised. A similarity property found only **11 of 300** generated pairs crossed the threshold
that reaches the only interesting arithmetic. Pair every generator with an assertion that it
produces the shape under test.

Note that `contract_holds/2` draws each argument independently and so **cannot produce a
correlated pair**. When similarity between arguments is the point, it has to come from a tight
pool. Likewise, a small key space is a *feature* for `server_invariants_hold/2` — random keys
produce sequences where no two messages touch the same key, exercising none of the coordination.

**Size a coverage guard from a distribution, not one sample.** A guard asserting
`collapsed > 2` over 300 samples, written on the strength of having measured 4 once, failed about
one run in thirty — the true minimum at that size was exactly 2. Measure the range over many
draws, buy headroom with **sample size** rather than a lower threshold, and record the measured
range in a comment beside the assertion.

### A property inherits its contract's blind spots exactly

`contract_holds/2` uses the contract as its oracle, so it sees precisely what the contract sees.
Measured: against a mutation that turned `"scope" => ""` into `[""]`, a property running 1100
checks **passed**, while a single example asserting `scopes == []` failed. The invariant was
`is_list/1` — a type check, the weakest kind.

So a property does not subsume the examples it is drawn over; it widens the *inputs* your
existing oracle judges. Point `contract_holds/2` at a function whose contract states a **law
about the output** over an input space too large to enumerate.

## `Bond.Server` callbacks

Because invariants are woven into the callbacks, you can call them as plain functions:

```elixir
contract_holds &Counter.handle_call/3,
  args: [
    StreamData.constant(:inc),
    StreamData.constant({self(), make_ref()}),
    StreamData.map(StreamData.non_negative_integer(), &%{count: &1})
  ]
```

One property checks the callback's own contracts, the `@state_invariant` on the returned state,
and the `@transition_invariant` relating the incoming state to it.

**Your state generator must produce *reachable* states.** An invariant guards the state a
callback *produces*, not the one passed in — so feeding a state the server could never be in
yields a spurious counterexample. That is also the honest limitation of the direct-callback
approach: it explores the states *you generate*. `server_invariants_hold/2` explores the ones the
server can actually reach.

Its `:mode` matters for mocks. Default `:callbacks` runs in the test process, so a private-mode
`Mox.stub` in `setup` is in scope. `:process` spawns a real server that will not see those
expectations — use `Mox.set_mox_global` with `async: false`, or `Mox.allow/3`. Prefer
`:callbacks`. Either way, **state gated behind a collaborator's reply is only reachable via that
reply**: a branch that runs only when an API call fails is never reached under a success stub,
however long the sequence. Split runs by outcome.

## Coverage, and the workflow it prompts

```elixir
# config/test.exs
config :bond, coverage: true
```

```elixir
# test/test_helper.exs
ExUnit.start()
Bond.Coverage.install_reporter()
```

After each suite you get a table of which assertions ran and how often they were false:

```
      @state_invariant :non_negative        checked  1184×  failed     3×  ✓
      @post :keeps_input                     checked   642×  failed     0×  ⚠ never failed
```

`⚠ never failed` is a **question, not a complaint**, with three answers:

| Why it cannot fail | What to do |
| --- | --- |
| It transcribes *how* the body works | Restate it as *what* the function promises |
| The body guards the property twice | Delete the redundant guard, keep the contract |
| It is a true law of a pure function | Keep it — prove it by **mutation**, not by a test |

The third is the common case, and in a mature codebase **most rows will read `⚠ never failed`**.
That is what a green suite means. Skim the table for a contract that looks suspiciously safe;
don't drive it to zero.

**Mutation is the proof for that third row.** Break the implementation deliberately, confirm the
contract fires, restore. It answers a question nothing else in the toolchain asks — and it
catches gaps in the *tests* rather than the contract at least as often. Three real cases where a
mutation survived and the contract was fine:

  * Every fixture happened to give every artist a name, so a filter's postcondition never saw the
    shape it guards.
  * Every test refreshed an already-clean connection, so "clears failure state" looked identical
    to clearing nothing.
  * A test named "a gap does not shift positions" passed under a rewrite that counted by index —
    because on the captured album, track number happened to equal list position for all fourteen
    items. A multi-volume release, where disc 2 restarts at track 1, is the discriminating case.

**When a mutation survives, look first at whether your fixtures contain the case the contract
describes.** A real fixture is not automatically a discriminating one, and when a test's name
states a distinction, check the data actually exhibits it.

Contracts and tests catch different things, and it is not a stylistic split:

| | Catches |
| --- | --- |
| Contracts | Structural violations — wrong element, wrong count, out of range, relationship broken |
| Example tests | Wrong values that are structurally fine |
| Property tests | Laws relating two *different* calls — order-independence, agreement between two spellings of one input |

A bound cannot see a value that is wrong but in range. When a mutation survives, the question is
which of the three is missing.

## Gotchas

  * **A shrunk counterexample may render a list of small integers as a charlist.**
    `[{:transformer, :apply_discount, ~c"e"}]` is showing you `[101]`. The rendering comes from
    ExUnitProperties, not Bond.
  * **Destructuring heads.** If a function destructures in its head, the generator for that
    argument must produce shape-matching values.
  * **Layered contracts fail-fast in execution order.** If a test asserts on *which* contract
    fired, target it by `label` (and `source_behaviour` for inherited ones) rather than relying
    on ordering.
