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

## Which tool when

| You want to check… | Use | Module |
| --- | --- | --- |
| A specific call violates a contract | `assert_precondition_violation` and friends | `Bond.Test` |
| A specific valid call succeeds | just call it and assert the result | — |
| Contracts hold over random *valid* inputs | `contract_holds/2` | `Bond.PropertyTest` |
| …and probe the *boundaries* the `@pre` implies | `probe_contract/2` | `Bond.PropertyTest` |
| Invariants hold across random *stateful sequences* | `invariants_hold/2` | `Bond.PropertyTest` |

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
    {:bond, "~> 1.7"},
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
  * `assert_invariant_violation/2` → `Bond.InvariantError`
  * `assert_state_invariant_violation/2` → `Bond.StateInvariantError` (`Bond.Server`)
  * `assert_transition_invariant_violation/2` → `Bond.TransitionInvariantError` (`Bond.Server`)

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

### `probe_contract/2` — one function, boundary-driven

`probe_contract/2` reads the literal comparisons in a function's `@pre`
(e.g. `amount >= 0`, `amount <= 100`) and mixes the implied **boundary values** into
your generators, so the property hits the edges — where off-by-one postcondition bugs
live — deliberately rather than by chance. It also uses the precondition as a
**filter**: an input that violates `@pre` is *discarded* (a generation miss, not a
failure) instead of failing the property, leaving the `@post`/`check` contracts as the
oracle on the inputs that survive.

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
`probe_contract/2` degrades gracefully to plain generated testing.

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

## Patterns and gotchas

  * **Choosing `contract_holds` vs `probe_contract`.** If writing a generator that
    produces only valid inputs is easy (`StreamData.float(min: 0.0)`), `contract_holds/2`
    is the most direct tool. If the precondition is interesting at its edges, or you want
    to generate broadly without hand-constraining every generator, `probe_contract/2`
    earns its keep.

  * **`probe_contract/2` and over-restrictive preconditions.** Because it filters by
    `@pre`, a precondition that rejects most generated inputs will make StreamData raise
    its standard "too many filtered" error. Narrow your base generators toward the valid
    range (as with `StreamData.integer(-5..105)` above), or use `StreamData.bind/2` for
    relational preconditions, so valid inputs are produced often enough.

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
