# Frequently Asked Questions

## Why contracts when I have ExUnit?

Tests verify behaviour for the specific scenarios you've written. Contracts
verify behaviour on **every call** in the running system. They catch
violations you didn't think to test for, especially in long-running dev or
staging environments. Tests and contracts complement each other:

- Tests describe what your code *should* do.
- Contracts describe what your code *must always be true while doing*.

For functions that are easy to test and have well-known input shapes,
tests alone are usually fine. For functions whose preconditions are
nuanced or whose results have invariants that span many call sites,
contracts catch bugs sooner with less work.

## Will contracts slow down my production code?

Not if you `:purge` them. Bond supports
[compile-time conditional compilation](configuration.md):

```elixir
# config/prod.exs — strip contracts entirely from this build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  invariants: :purge,
  checks: :purge
```

When every contract kind on a function is `:purge`d, Bond emits no override
at all and the function runs with zero per-call overhead. The compiled BEAM
contains no contract evaluation code for that function.

Purge from the top down: the contract-checking chain requires that if you
`:purge` a kind, every kind above it is `:purge`d too, so
`preconditions: :purge` without `invariants: :purge` is a compile error. See
[Why can't I have postconditions on while preconditions are off?](#why-can-t-i-have-postconditions-on-while-preconditions-are-off)
below.

Purging everything is one posture, not the only one. Keeping preconditions —
the cheapest kind, and the only one that catches a caller's bug — while purging
the rest is a common middle ground, and `false` keeps checks compiled in but
inert so a remote console can switch them on mid-incident. See
[Choosing what runs in production](configuration.md#choosing-what-runs-in-production).

For concrete numbers — how many nanoseconds each contract kind adds per
call, and how much compile time Bond costs per module — see the
[Overhead](overhead.md) guide. Headline figures from the reference
environment: a `:purge`d contract is free; an enabled `@pre` adds ~75
ns/call; an enabled `@invariant` (entry + exit) adds ~215 ns/call; Bond
compile-time overhead is ~30 ms per module that uses contracts.

## Can I toggle contracts at runtime without recompiling?

Yes — that's what `true` and `false` (as distinct from `:purge`) give you.
When a kind is compiled with `true` or `false`, the override has a runtime
guard. Flip it with `Bond.Config`:

```elixir
# In IEx or a remote console:
Bond.Config.disable(:preconditions)  # dormant
Bond.Config.enable(:preconditions)   # active again

Bond.Config.put(:postconditions, false)  # set a kind explicitly
Bond.Config.all()                         # inspect the effective state
```

The runtime check is a single lock-free `:persistent_term` read (~6 ns) —
about 5× cheaper than the `Application.get_env/3` lookup it replaced in
1.1.0. For inner-loop hot paths, `:purge` is still the right choice — the
runtime toggle costs a tiny read; `:purge` costs nothing.

> #### `Application.put_env` is not a live toggle {: .warning}
>
> The runtime state is seeded from application env on the *first* contracted
> call, then cached in `:persistent_term`. Calling
> `Application.put_env(:bond, :preconditions, false)` after that point has no
> effect. Use `Bond.Config` (which updates the cache directly), or
> `Bond.Config.reset/0` to re-seed from current application env.

## Can I disable contracts for one specific module?

Yes, two ways.

In the source:

```elixir
defmodule MyApp.HotPath do
  use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge
end
```

Or in config (handy when you don't want to touch the source):

```elixir
config :bond,
  overrides: [
    {MyApp.HotPath, preconditions: :purge, postconditions: :purge, invariants: :purge},
    {~r/Workers\./, postconditions: false}
  ]
```

Exact module atoms match precisely. `Regex` patterns match against the
source-visible module name. The `use Bond` opts override `:overrides`,
which override the global config.

## How does Bond compare to Norm?

[Norm](https://github.com/elixir-toniq/norm) validates **data shapes** — a
value matches a spec or it doesn't. Bond verifies **function behaviour** —
a contract asserts something about the relationship between inputs,
outputs, and (optionally) prior state.

The two libraries are conceptually complementary. By default they can't
share a module — both override `Kernel.@/1` — but Bond's `at_annotations: false`
escape hatch lets them coexist, including on the same function (see
[the next FAQ entry](#can-i-use-bond-and-norm-in-the-same-module)).
You can also call Norm's validation helpers from a Bond module as
ordinary remote calls:

```elixir
defmodule MyApp.Boundary do
  use Bond

  @pre matches_input_spec: Norm.valid?(input, MyApp.Specs.input())
  @post matches_output_spec: Norm.valid?(result, MyApp.Specs.output())
  @post "no items lost": length(result) == length(input)
  def transform(input), do: ...
end
```

…where `MyApp.Specs` is a separate module that does `use Norm` and
defines `input/0` and `output/0` with Norm's `spec/1`.

## Can I use Bond and Norm in the same module?

**Yes — pass `at_annotations: false` to `use Bond`.**

By default, `use Bond` and `use Norm` in the same module fail to compile
with:

```
function @/1 imported from both Bond and Norm.Contract, call is ambiguous
```

Both libraries use the same technique to intercept module attributes:
`import Kernel, except: [@: 1]` followed by importing their own `@/1`
macros. When both `use` lines land in one module, both imports end up
at the same scope level — Elixir does not pick a winner — and the first
`@`-using line fails. The error is loud and points at the offending
line; contracts are never silently dropped.

### The escape hatch: `use Bond, at_annotations: false`

`at_annotations: false` tells Bond to leave `Kernel.@/1` untouched in that
module, so Norm keeps ownership of `@` (and thus `@contract`). Bond's
compiler hooks are still installed, but you write Bond contracts as
fully-qualified calls — `Bond.pre/1`, `Bond.post/1`, and `Bond.invariant/1`.
`check/1` remains available unqualified.

```elixir
defmodule MyApp.Boundary do
  use Norm
  use Bond, at_annotations: false

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  # Guarded by Norm's @contract AND Bond's precondition — the two wrappers
  # compose, each delegating to the next via `super`.
  @contract scale(n :: positive_int()) :: positive_int()
  Bond.pre even: rem(n, 2) == 0
  def scale(n), do: n * 2

  # A Bond-only function in the same module.
  Bond.pre positive: x > 0
  Bond.post result == x * 2
  def double(x), do: x * 2
end
```

The bare `pre`/`post`/`invariant` macros are **never** imported — even
under the default `at_annotations: true` — so they can't collide with common
function names like `post`. They're reachable only as `Bond.pre`,
`Bond.post`, and `Bond.invariant`. Note that the formatter writes
qualified calls with parentheses (`Bond.pre(x > 0)`); this is why the
`@pre` form remains the recommended, more readable default for modules
that don't need to coexist with another `@`-overriding library.

### Limitation: at most one `@contract` per module

Norm's `@contract` does two things: it wraps the contracted function
(via `defoverridable`), and it emits a small `def __contract__/1` helper
clause — one per `@contract`. Bond [tolerates the override
clause](#can-i-use-bond-with-decorator-or-other-libraries-that-wrap-functions),
but two or more `@contract`s produce non-adjacent `__contract__/1` clauses
that still trip Bond's clause-grouping check. If you need more than one
Norm contract alongside Bond, split into separate modules (below) or keep
the extra contracts in a Norm-only module.

### Alternative: split into separate modules

Each library in its own module, one calling the other — always works, and
sidesteps both the `@` clash and the multiple-`@contract` limit:

```elixir
defmodule MyApp.Specs do
  use Norm

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  @contract validate(n :: positive_int()) :: positive_int()
  def validate(n), do: n
end

defmodule MyApp.Worker do
  use Bond

  @pre is_integer(n)
  @post result == n * 2
  def double(n) do
    n = MyApp.Specs.validate(n)
    n * 2
  end
end
```

### Alternative: use Norm's data helpers without `use Norm`

If you only need Norm's data-shape helpers (`spec/1`, `conform/2`,
`valid?/2`) inside a Bond module, call them as ordinary remote calls
on the `Norm` module — no `use Norm` required, so you keep the `@pre`
syntax:

```elixir
defmodule MyApp.Worker do
  use Bond

  @pre positive: Norm.valid?(n, positive_int_spec())
  def double(n), do: n * 2

  defp positive_int_spec, do: Norm.spec(is_integer() and (&(&1 > 0)))
end
```

This keeps Bond's `@/1` interception intact and uses Norm only for
spec construction and validation.

## Can I use Bond with `decorator` or other libraries that wrap functions?

**Yes.** Libraries that wrap functions — the
[`decorator`](https://github.com/arjan/decorator) library, Norm's
`@contract`, and similar — do so by making the function `defoverridable`
and redefining it to call the original via `super`. That redefinition
fires Bond's `@on_definition` callback, so Bond used to see the function
defined twice and reject it ("clauses ... must be grouped together").

Bond now detects these externally-generated override clauses (a clause
that is `defoverridable` at definition time is a wrapper, not a hand-written
clause) and ignores them for tracking purposes. Bond still wraps the
function as a whole with its own contract check, composing with the other
library's wrapper through `super`:

```elixir
defmodule MyApp.Job do
  use MyApp.Telemetry   # a decorator-style library that wraps functions

  use Bond

  @decorate timed()
  @pre valid: is_map(args)
  def perform(args), do: run(args)
end
```

Here a call to `perform/1` runs Bond's precondition, then the telemetry
wrapper, then the original body. The only requirement is that contracts
attach to your hand-written clause — which is the normal case; you don't
write the wrapper, the other library generates it.

This tolerance only changes a situation that previously always raised a
compile error, so it can't affect code that already compiled.

## Why can't I have postconditions on while preconditions are off?

Because a postcondition failure when preconditions weren't checked is
diagnostically misleading — it might really be the caller's fault, not
the function's. Bond's contract-checking chain says:

```
preconditions ≤ postconditions ≤ invariants
```

Concretely:

- **Compile-time:** if you `:purge` a lower kind, you must `:purge`
  every higher kind too. `config :bond, preconditions: :purge` while
  leaving `:postconditions: true` is a compile error.
- **Runtime:** if you `Bond.Config.disable(:preconditions)`,
  postconditions and invariants are also skipped automatically. Bond
  emits a one-time `Logger.warning` per process per (higher, lower)
  pair so you know it happened.

`:checks` is independent of the chain — `check/1` is an internal
sanity assertion, not a contract with a caller.

If you genuinely want to skip a higher kind's *evaluation* without
removing the code, use `false` instead of `:purge` (compiled in,
runtime-disabled by default; flippable via `Bond.Config`).

## How do I disable a single failing contract while debugging?

Bond intentionally has no per-contract on/off knob. The contract toggles
that exist are coarser by design — per-kind (`:preconditions`,
`:postconditions`, `:invariants`, `:checks`) and per-module (via
`:overrides` or `use Bond` options) — because a contract is part of a
function's stated agreement with its caller, and adding a fourth axis of
"this individual assertion is off" tends to mask broken agreements
rather than resolve them. For debugging, pick whichever of these fits:

1. **Comment it out.** Simplest, and the right answer most of the time.
   Add a `TODO` so it doesn't stay commented past the debugging session.
2. **Move the assertion to `check/1` inside the body.** `check/1` is
   wrappable in a conditional and is the right home for an assertion
   you want to gate on runtime state (e.g. a feature flag) rather than
   on contract policy.
3. **Disable the kind globally.** If you're investigating a precondition
   storm in dev, `config :bond, preconditions: false` in `config/dev.exs`
   skips all preconditions from boot, without recompiling consumers; or
   call `Bond.Config.disable(:preconditions)` for a live toggle in the
   current session (e.g. from an IEx console). Heavy-handed but cheap. The
   chain rule (preconditions ≤ postconditions ≤ invariants) means
   disabling preconditions also skips the higher kinds; see "Why can't
   I have postconditions on while preconditions are off?" for why.

## What does Bond do that typespecs don't?

Typespecs are static documentation of input and output **types**. Tools
like Dialyzer can verify them statically, but typespecs cannot express:

- Relationships between arguments (`amount <= balance`).
- Relationships between input and output (`result <= balance`).
- Conditional invariants (`(x == 0) ~> (result == 0.0)`).
- State-change properties using `old/1`.
- Arbitrary computed predicates.

Typespecs say "this argument is an integer." Contracts say "this argument
is a positive integer less than the balance, and the result is the
balance minus the argument." Use both.

## Should I remove guards and pattern matches when I add contracts?

It depends on what the guard is doing — and the question is worth taking
seriously, because Design by Contract has a rule about it. Bertrand Meyer calls
it the **Non-Redundancy Principle** (*Object-Oriented Software Construction*,
2nd edition, §11.6, p. 343):

> Under no circumstances shall the body of a routine ever test for the routine's
> precondition.

Either the condition is in the `require` clause, or it is in an `if` in the
body — never both. Meyer presents this as the opposite of defensive programming:
a condition checked in two places belongs to nobody, and the duplicate code is
extra surface for bugs rather than extra safety.

An Elixir guard is not quite Eiffel's `if`, though, which is what makes the
answer three-way:

| What the guard is doing | Example | Keep it? |
|---|---|---|
| **Selecting a clause** | `def parse(x) when is_binary(x)`, beside a `when is_list(x)` clause | **Yes.** It's dispatch, not a check — delete it and different code runs. |
| **Standing in for a type** | `when is_binary(email)` | **Yes.** This is Elixir's `email: STRING`. Don't restate it as a `@pre`. |
| **Stating a domain rule** | `when amount <= account.balance` | **Pick one.** This is the case the principle governs. |

Only the third is redundancy in Meyer's sense. The first two live in the
signature rather than the body: Eiffel's answer to "is this a string?" is the
declared type, and nothing in Design by Contract asks you to drop that.

For the third, choose by **whose fault a violation is**. If calling with an
amount over the balance is the caller's mistake, that is a precondition — write
`@pre sufficient_funds: amount <= account.balance` and drop the guard. If the
function is meant to cope with it, it isn't a precondition at all: handle it in
the body and return `{:error, :insufficient_funds}`.

### Why not keep both, just in case?

Because a `@pre` that restates a guard can never fire. Bond reproduces your
`when` guards on the wrapper clauses so multi-clause dispatch keeps working, so
an argument that fails the guard raises `FunctionClauseError` *before* any
precondition is evaluated. The `@pre` is unreachable as a
`Bond.PreconditionError` — an assertion you will never see fail, which is
exactly what [Writing sound assertions](writing-sound-assertions.md) is about.
Bond's assertion linter cannot catch this one (it only warns where it can
*prove* an assertion constant), so it stays advice rather than a warning.

Note the boundary: this is about a `@pre` the guard *already rejects everything
of*. A `@pre` that is **stronger** than the guard can fail and is worth keeping —
`@pre even_amount: rem(amount, 2) == 0` on a function guarded by
`when is_integer(amount)` fires on `3`. "There is a guard" is not the test;
"the guard already rejects everything this rejects" is.

### Then how do I get the requirement into the docs?

With a `@spec`, for anything a type can say. This is the one real cost of
dropping a guard-restating `@pre`: guards are invisible in generated
documentation, so deleting the contract does lose something. But a `@spec`
recovers it and more — ExDoc renders it directly under the signature, *above*
Bond's generated contract sections, and Dialyzer checks it, which a `@pre` never
does:

```elixir
@spec send_welcome(String.t(), String.t()) :: :ok
def send_welcome(to, name) when is_binary(to) and is_binary(name), do: ...
```

That is Design by Contract's own division rather than a workaround. Eiffel puts
types in the declared parameter types and reserves `require` for what types
cannot express; `@spec` and `@pre` split the same way. See
[What does Bond do that typespecs don't?](#what-does-bond-do-that-typespecs-don-t)

### But contracts can be purged — isn't the guard my safety net?

This is the strongest argument for keeping both, and Meyer's answer is that it
points at a misclassification rather than a need for redundancy. If a condition
has to hold in a build with contracts compiled out, it was never a precondition:

  * **Data from outside the system** — a request body, a config file, a CSV
    row — has no contract to violate, because there is no caller of yours to
    blame. Validate it at the boundary with ordinary code, and let the functions
    behind that boundary take preconditions about data already known to be good.
  * **A condition you don't trust callers to meet** is a statement that the
    function is tolerant rather than demanding. Say so in the body, and return a
    value.
  * **A condition you do trust callers to meet** is a precondition, and purging
    it in production is the trade you chose when you purged — the same trade as
    switching off any other assertion.

### Consequence for tests

Use `Bond.Test.assert_precondition_violation/2` for preconditions with *no*
corresponding guard — semantic constraints only a contract can express, like a
cross-field relationship. Where a guard is doing the work, assert
`FunctionClauseError` instead, because that is what fires and what should fire.

The division of labour that falls out: guards and patterns say what the function
*accepts* and which clause handles it; contracts say what it *promises* — the
relationships between arguments, and between arguments and the result, that a
guard cannot express at all.

## How demanding should my preconditions be?

Once the Non-Redundancy Principle has told you that a condition belongs to
exactly one party, you still have to choose which. Meyer names the two attitudes
(*Object-Oriented Software Construction*, 2nd edition, §11.7, p. 354): the
**demanding** style puts the condition in the precondition and expects callers
to establish it; the **tolerant** style leaves it out and handles the case in
the body.

He is careful to mark this one as a judgement rather than a law — "to a certain
extent this is a matter of personal choice (as opposed to the Non-Redundancy
principle, which was absolute)" — while still making "a strong case […] for the
demanding style, especially in the case of software meant to be reusable."

The argument is about **context**. A general-purpose routine usually does not
have enough of it to decide what an out-of-range call *means*. Meyer's example
is popping an empty stack: only the caller knows whether that is a harmless
no-op, a recoverable condition, or a bug. A stack module that picks one on the
caller's behalf — his tolerant version prints an error message — has
overstepped. The same goes for a square root of a negative number, where the
tolerant body reduces to `if x < 0 then "handle the error, somehow"`. As he puts
it, the operative word is *somehow*.

### The Elixir translation is three ways, not two

Elixir needs a distinction Eiffel doesn't, and getting it wrong would turn good
advice into bad advice. There are three things you can do with an out-of-range
input, not two:

1. **Demand it.** `@pre non_empty: items != []`. Violating it is a bug in the
   caller, and Bond says so.
2. **Return it.** `{:error, :empty}`. The function reports the condition and the
   *caller still decides* what it means.
3. **Guess.** Log something, return `nil`, substitute a default, carry on.

Only (3) is what Meyer attacks. Idiomatic Elixir's `{:ok, _} | {:error, _}` is
**not** the tolerant style he warns about — it delegates the decision rather
than making it, which is the same instinct the demanding style is protecting.
So "prefer demanding" here means *prefer (1) or (2) over (3)*, and never
"stop returning error tuples."

Choose between (1) and (2) by asking what a violation *is*. If reaching this
state means somebody upstream has a bug, it is a precondition. If a correct
caller with valid data can legitimately land here — an empty result set, a
missing key, a closed account — it is a normal outcome and belongs in the return
value. Bond sharpens the question: a precondition can be purged and an
`{:error, _}` cannot, so anything a running system must still handle when
contracts are compiled out has to be (2).

### Don't over-demand: the Reasonable Precondition principle

The demanding style has an obvious failure mode — `require False` makes every
routine trivially correct — so Meyer bounds it (§11.7, p. 356):

> **Reasonable Precondition principle**
>
> Every routine precondition (in a "demanding" design approach) must satisfy the
> following requirements:
>
>   * The precondition appears in the official documentation distributed to
>     authors of client modules.
>   * It is possible to justify the need for the precondition in terms of the
>     specification only.

Bond gives you the first for free: contracts are appended to the generated docs,
so a precondition you write is a precondition your callers can read.

The second is a test worth applying by hand, because it rules out the
preconditions that exist for *your* convenience rather than from the problem.
"There is no maximum of an empty collection" justifies `@pre non_empty: items != []`
on `max/1` from the specification alone. "My implementation calls `Map.get/2`"
does not justify `@pre is_map(opts)` — that is an implementation detail leaking
into the caller's obligations, and the day you switch to a keyword list the
caller's contract changes for no reason the caller can see.

## Can I write a contract for the failure path?

Yes — if you model failure the way Elixir recommends, as a **value**. Bond
has no exception contract (no `signals`/`throws` clause), deliberately.

For a function that returns `{:ok, _} | {:error, reason}`, `@post` already
gives you both halves of a failure contract. Constrain the set of failures
a function is allowed to produce:

```elixir
@post only_known_errors:
        match?({:ok, _}, result) or
          match?({:error, r} when r in [:insufficient, :frozen, :unknown_account], result)
def withdraw(account, amount), do: ...
```

An undeclared error tag now fails the postcondition with
`label: :only_known_errors`. And to say what must hold *when* a particular
failure occurs, scope it with `whenever` — `old/1` is available, so you can
relate the failure to the state at entry:

```elixir
@post whenever({:error, :insufficient} <- result),
      untouched: ledger_total() == old(ledger_total())
```

### Why there is no exception contract

For raised exceptions, three things take the motivation away.

**"State is unchanged on failure" is a tautology here.** The classic reason
failure contracts exist is that a failed operation can leave its target
half-mutated. Elixir's data is immutable, so a caller's value cannot change
no matter what the callee does or how it fails. An assertion like
`account.balance == old(account.balance)` on the failure path can never be
false.

**A crashed process has no state left to constrain.** If a `GenServer`
callback raises, the process dies and its state is discarded; the supervisor
restarts it from a known-good one. There is no inconsistent state surviving
the failure for a contract to check.

**Enforcing "may only raise X" would have to change what propagates.** To
report the violation, Bond would have to replace or wrap the exception that
was already on its way out — breaking `rescue` clauses that matched the
original type, and making a build with contracts purged fail *differently*
from one with them enabled. Every other Bond contract only adds a check;
this one would alter the failure itself.

So exception expectations belong where they already work well:
`assert_raise/2` in your tests for the behaviour, and `@doc` plus the `!`
naming convention for the documentation.

The one case this genuinely leaves uncovered is a function that mutates
**external** state — ETS, a database, a file — and raises partway through,
where "if this raised, nothing was written" is a real property. That is
normally a transaction's job rather than a contract's.

## Should I rescue a `Bond.PreconditionError`?

Not to decide what your program does next. Bond's error structs are ordinary
exceptions and nothing stops you catching them, but a contract violation is a
different kind of event from a failure your code is meant to handle. Meyer puts
it as a rule: a run-time assertion violation is the *manifestation of a bug* —
a precondition violation is a bug in the caller, a postcondition violation a bug
in the function. Neither is a business outcome, and turning one into a return
value converts a bug report into a feature.

Bond gives this the sharpest possible edge, because a `rescue` that branches on
a contract violation **behaves differently in a purged build**:

```elixir
def safe_charge(amount) do
  charge(amount)
rescue
  Bond.PreconditionError -> {:error, :invalid_amount}
end
```

With contracts enabled, `safe_charge(-5)` returns `{:error, :invalid_amount}`.
Compile the same source with `preconditions: :purge` and it returns
`{:ok, -5}` — the precondition never fires, the `rescue` never runs, and the
negative amount sails through. The error branch didn't get slower; it stopped
existing. This is the same hazard
[Writing sound assertions](writing-sound-assertions.md) describes for partial
assertions: a contract should never be the reason two builds of the same source
disagree about what a function returns.

If `amount > 0` is a condition your program must handle rather than a promise
callers must keep, it is not a precondition. Check it with ordinary control flow
and return `{:error, :invalid_amount}` yourself — see
[Can I write a contract for the failure path?](#can-i-write-a-contract-for-the-failure-path)
above.

Catching Bond errors to *report* them is a different matter and perfectly
reasonable: a `Plug.ErrorHandler`, a `Logger` in a supervision tree, an error
tracker's exception hook. Those observe the bug and let it stay a bug. For
counting and alerting without any `rescue` at all, the
[`[:bond, :assertion, :failure]` telemetry event](telemetry.md) fires on every
violation, before the exception is raised.

## Are contracts evaluated on the recursion path?

No — Bond implements Bertrand Meyer's
[Assertion Evaluation rule](https://en.wikipedia.org/wiki/Design_by_contract):

> During the process of evaluating an assertion at run-time, routine
> calls shall be executed without any evaluation of the associated
> assertions.

If a postcondition calls another contracted function, that inner
function's preconditions and postconditions are *not* evaluated. Without
this rule, mutually recursive contracts would loop forever. With it,
contracts are safe to use even when they call into the rest of your API.

Termination is the obvious reason but not Meyer's main one. His argument is that
evaluating a predicate's contracts while it is checking yours would "treat as peers the
routines of our computation and their assertions' functions", when assertions are meant
to sit on a higher plane than the code they police — their correctness has to be settled
in advance, not audited mid-flight. His analogy: you run the background check on the
security guard before their shift, not while they are screening visitors. The practical
consequence is in
[How do I reuse a predicate across several functions?](#how-do-i-reuse-a-predicate-across-several-functions)
— a predicate you use in contracts must stand on its own.

## Can I use `check/1` to assert input validity?

No — `check/1` is for **sanity checks during development**, not input
validation. A `check` can be switched off with `config :bond, checks: false`
(or removed from the build entirely with `checks: :purge`), and the wrapped
expression is then not evaluated at all. If your code's correctness depends
on something being checked, use ordinary control flow:

```elixir
# DON'T: relies on check for correctness
def withdraw(balance, amount) do
  check amount > 0
  balance - amount
end

# DO: explicit guard, evaluated regardless of config
def withdraw(balance, amount) when amount > 0 do
  balance - amount
end
```

## Why does my error message report `sqrt/2` when I wrote `sqrt/1`?

If the function has a default argument, like
`def sqrt(x, trap_door \\ nil)`, Elixir generates clauses for both arities
(`sqrt/1` and `sqrt/2`). Bond attaches the contract to the higher-arity
clause, so error messages report `sqrt/2` even when the caller writes
`Math.sqrt(-1)` (which Elixir dispatches via the auto-generated `sqrt/1`
forwarder).

This is expected. If you want the error to mention `sqrt/1`, split the
default-arg form into explicit clauses.

## How does Bond compose with StreamData / property-based testing?

Contracts and property-based testing are natural partners: PBT's hard
part is usually writing the oracle that says whether an output is right
or wrong, and contracts *are* that oracle. `Bond.PropertyTest` exposes
this directly with three macros:

```elixir
use Bond.PropertyTest

# contract_holds/2: random inputs into a single function
contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

# probe_contract/2: like contract_holds/2, but mixes the boundary values
# implied by @pre into the generators and filters out inputs that violate
# @pre — so @post is the oracle and the precondition edges are probed
probe_contract &Account.withdraw/2, args: [account_gen(), StreamData.integer()]

# invariants_hold/2: random sequences over a struct's @invariant
invariants_hold BoundedStack,
  constructors: [{:new, [StreamData.integer(1..100)]}],
  transformers: [{:push, [StreamData.term()]}, {:pop, []}]
```

`stream_data` is an optional dep of bond — add it to your own project
when you want PBT. The [Testing Contracts](testing-contracts.md) guide
covers all three property-based macros (and `Bond.Test`'s example-based
assertions) in full, including when to use which.

## When does Bond check invariants?

`@invariant` declarations on a struct module are checked automatically at
the boundaries of that module's public functions. Bond auto-detects the
struct parameter in the function head and pre-checks against it:

- **On entry**, when the function head matches the struct in any of these
  shapes (Bond detects all three):
    - `def foo(%__MODULE__{} = name, ...)` — explicit pattern with binding.
    - `def foo(x, ...) when is_struct(x, __MODULE__)` — bare param plus
      guard (including arbitrary nesting inside `and` / `or`).
    - `def foo(%__MODULE__{field: v}, ...)` — destructure-only. Bond
      rewrites the override clause to capture the struct under a
      generated name so the pre-check still fires.
- **On exit**, against the return value if it's `%__MODULE__{}` or
  `{:ok, %__MODULE__{}}`. Other return shapes fall through without a
  check. If your function wraps the struct differently, add an explicit
  `@post`.
- **For multi-struct heads** like `def merge(%__MODULE__{} = a,
  %__MODULE__{} = b)`, both parameters are checked in left-to-right
  order, with the implicit `subject` rebinding to each in turn.
- **Never for `defp`** — private functions are exempt by the Eiffel
  convention (they often hold transiently-invalid state mid-operation).

The on-exit check is a **runtime** shape test, not a static one: it is
emitted for every public function in an invariant-declaring module and
matches whatever the function actually returns. So it fires no matter
*how* the struct was built — `struct/2`, a `case`, a helper call, a
pipeline. Only the on-entry check depends on Bond recognising a shape
at compile time.

A function with neither a struct-matching head **nor** a struct-shaped
return value skips invariants entirely; the other contract kinds still
apply. Bond emits a compile-time warning when it can see that coming —
see the next entry.

Violations raise `Bond.InvariantError` and emit `[:bond, :assertion, :failure]`
telemetry with `:kind => :invariant`. See the [Invariants](invariants.md) guide.

## Why is Bond warning about skipped invariants?

You're seeing something like:

```
public function `update/2` in invariant-declaring module
`MyApp.BoundedStack` never mentions the struct: no clause matches
`%MyApp.BoundedStack{}` in its head or builds one in its body, so the
entry check is skipped and invariants are skipped here. (The exit check
still fires if this function returns a `%MyApp.BoundedStack{}` at
runtime.) If intentional, suppress with
`@bond_warn_skipped_invariants false` (per function), `use Bond,
warn_skipped_invariants: false` (per module), or `config :bond,
warn_skipped_invariants: false` (globally).
```

Bond's invariants fire in two places: on entry (when the function head
pattern-matches the struct, giving Bond a `subject` to bind) and on
exit (a runtime shape test on the return value). The warning fires when
a public function (`def`, not `defp`) in an invariant-declaring module
**never mentions the struct at all** — no `%__MODULE__{}` pattern or
literal anywhere in the head, guards, or body, and no
`struct/2`/`struct!/2` call naming the module.

That is deliberately a wide net, because the exit check is a runtime
test and Bond cannot prove statically that it won't fire. If the struct
appears anywhere in the clause, Bond stays quiet — a function that
plainly handles the struct is not the footgun this warning is for:

```elixir
# All of these are silent: the struct is mentioned, so the runtime
# post-check has something to match, and it does.
def unwrap({:wrapped, %__MODULE__{} = s}), do: s   # nested in a pattern
def new(v), do: struct(__MODULE__, v: v)           # dynamic constructor

def build(opts) do
  state = %__MODULE__{count: opts[:count]}
  {:ok, state}                                     # struct in a variable
end
```

> #### This warning used to be noisier {: .info}
>
> Earlier versions ran this check on a narrow static heuristic — only a
> literal `%__MODULE__{...}` or `{:ok, %__MODULE__{...}}` return
> suppressed it — so all three functions above warned even though their
> invariants demonstrably ran. If you suppressed those with
> `@bond_warn_skipped_invariants false`, the suppression is now
> unnecessary and can be removed. It remains harmless.

**If the function is supposed to operate on the struct**, the fix is
usually a missing pattern or guard on the head:

```elixir
# Footgun — head doesn't match the struct, body doesn't return one:
def update(stack, x), do: Map.put(stack, :counter, x)

# Fixed — Bond detects the struct on entry and the @invariant fires:
def update(%__MODULE__{} = stack, x), do: Map.put(stack, :counter, x)
# or:
def update(stack, x) when is_struct(stack, __MODULE__), do: ...
```

See "When does Bond check invariants?" above for every shape Bond
detects on entry, and the shapes it recognises on exit.

**If the function is genuinely not about the struct** (a utility
function, a class-name helper), suppress the warning at the right
scope. From narrowest to broadest:

```elixir
# Per function — only this def. Other public functions in the same
# module keep the safety net.
@bond_warn_skipped_invariants false
def class_name, do: "Stack"
```

```elixir
# Per module — every public function in the module is exempt. Useful
# when the whole module legitimately doesn't operate on the struct
# (rare; reconsider whether @invariant belongs here at all).
use Bond, warn_skipped_invariants: false
```

```elixir
# Global — every module in the project. Use sparingly; you lose the
# footgun-catcher everywhere.
# config/config.exs
config :bond, warn_skipped_invariants: false
```

**Per-function is the right answer most of the time.** A typical
struct module has a few utility or constructor functions mixed in with
the struct-operating ones, and you want the warning to keep firing on
the latter if they're later refactored to drop the struct from their
head. Module-level suppression silences future regressions in the same
module, so reach for it only when you mean "this entire module isn't
about the struct."

The per-function override is a tri-state: omitting the attribute
inherits the module/global setting; `false` suppresses for that one
def; `true` re-enables the warning even under a module/global `false`
— useful for selectively opting back in to verify a specific
function under a project-wide suppression.

The warning is opt-out so the footgun is caught by default; all three
suppression knobs ship with 1.0 and are part of the public API.

## How are multi-clause functions handled?

A single contract applies **uniformly to every clause** of a multi-clause
function. Put your `@pre` and `@post` annotations before the first clause;
Bond emits one wrapper clause per user clause (each preserving the user's
pattern so Elixir's natural pattern-matching dispatch survives) and one
set of lifted assertion defps that all wrappers delegate to.

```elixir
@pre is_list(input)
@post is_atom(result)
def parse([:a | _]), do: :starts_with_a
def parse(input) when is_list(input), do: :other
```

Contracts must apply uniformly across clauses, so **all clauses must agree
on the top-level parameter name at each position a contract references**
(see ["Naming consistency is only required where contracts depend on
it"](#naming-consistency-is-only-required-where-contracts-depend-on-it)
below — positions no contract mentions are free to differ). The wrapper
uses the agreed name when it calls `super` and when it passes arguments to
the lifted contract defps — the names referenced in your assertion
expressions are the canonical names.

When a contract references a position whose clauses disagree on the
top-level name, Bond raises a `CompileError`:

```elixir
defmodule MyMod do
  use Bond

  @pre g != nil          # references position 1 (`g`)
  def lookup(conn, %Game{} = g, %GameFilm{} = f), do: ...
  def lookup(conn, league, conference) when is_binary(league), do: ...
  #                ^^^^^^
  # CompileError: position 1 disagrees on top-level names (`g` vs `league`).
  # The `@pre` references position 1, so the clauses must agree there.
  # (Position 2 also disagrees — `f` vs `conference` — but no contract
  # references it, so Bond doesn't enforce agreement at that position.)
end
```

The fix is to rename for consistent positional meaning across clauses —
usually a readability improvement too, since the original names described
one shape but the function accepts multiple:

```elixir
@pre resource != nil
def lookup(conn, %Game{} = resource, %GameFilm{} = scope), do: ...
def lookup(conn, resource, scope) when is_binary(resource), do: ...
```

For **shape-dependent** assertions, use the `~>` implication operator
from `Bond.Predicates`. It short-circuits the consequent when the
antecedent is falsy, so the consequent only runs for the shape it
applies to:

```elixir
@pre is_struct(resource, Game) ~> (resource.published)
@pre is_binary(resource) ~> (String.length(resource) > 0)
def lookup(conn, %Game{} = resource, scope), do: ...
def lookup(conn, resource, scope) when is_binary(resource), do: ...
```

Wildcard clauses (`def f(_)`) and literal-pattern clauses (`def f(0)`)
don't bind a top-level name at that position. They adopt whatever name a
sibling clause provides — Bond rewrites the wildcard or wraps the literal
to bind the canonical name in the wrapper's pattern.

**Underscore-prefixed names are equivalent to their unprefixed forms.**
A fallback clause like `def f(_a, _b, c)` paired with a contracted clause
`def f(a, b, c)` agrees on the canonical names `a`, `b`, `c` — Elixir's
leading-underscore convention is "bound but intentionally unused," and
Bond treats `_a` and `a` as the same binding for the consistency check.
Write fallback clauses with `_name` markers freely; the contracts still
attach.

That equivalence is also the answer to a wart you hit as soon as a head
destructures. When the body uses only the destructured fields, the `= name`
binding exists purely so a contract can reference the whole argument — and
Elixir, which cannot see into the generated assertion functions, warns that
`name` is unused:

```elixir
@pre is_api_spec: is_api_spec(api_spec)
def matches?(%{id: id} = api_spec, value), do: id == value
#                        ^^^^^^^^ warning: variable "api_spec" is unused
```

Prefix it. The contract keeps referencing the unprefixed name, and the
warning goes away:

```elixir
@pre is_api_spec: is_api_spec(api_spec)
def matches?(%{id: id} = _api_spec, value), do: id == value
```

Names destructured *inside* the pattern (`id` above) stay available to the
contracts of a single-clause function, prefixed or not.

### Naming consistency is only required where contracts depend on it

The naming-agreement rule applies *positionally*: only positions whose
top-level names are *referenced* by some assertion need to agree across
clauses. A contract that doesn't reference any parameter — for example
`@post is_boolean(result)` — doesn't constrain naming at all, even on
multi-clause functions whose clauses bind different names at every
position:

```elixir
@post is_boolean(result)
def can_access?(conn, %Game{} = game, %GameFilm{} = film), do: ...
def can_access?(conn, league, conference) when is_binary(league), do: ...
#                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# Positions 1 and 2 disagree on top-level names, but no contract references
# them — Bond doesn't enforce agreement at those positions. The `@post`
# compiles cleanly.
```

If you later add a contract that *does* reference one of the disagreeing
positions, the agreement rule re-engages at that position and the
`CompileError` fires. Trivial contracts (result-only, or referencing only
positions that already agree) are free to attach without first renaming
parameters across clauses.

`Bond.Predicates` helpers like `is_boolean/1` and other Kernel predicates
that take only `result` work as universal contracts on any multi-clause
function regardless of how its parameters are named per clause.

Bond raises a compile error if you put `@pre` or `@post` between clauses
— contracts attach to a function, not a clause:

```elixir
# COMPILE ERROR — contracts must precede the first clause
@pre x > 0
def foo(x) when is_integer(x), do: x * 2

@pre is_float(x)       # not allowed here
def foo(x) when is_float(x), do: round(x)
```

Per-clause contracts are out of scope for Bond 1.0 — by design.
Contracts describe the function's behavioural agreement with its caller,
which is one agreement per function regardless of how many clauses
implement it. If different clauses genuinely have different contracts,
that's a sign they're really two different functions; split them.

When the contract is the same across clauses but a parameter is named
differently in each clause, use a bodyless function head to attach the
contract to a single canonical parameter list, then define the clauses
with whatever names suit each:

```elixir
@pre is_integer(n)
def double(n)

def double(n) when n >= 0, do: n * 2
def double(n), do: -n * -2
```

The "Naming consistency is only required where contracts depend on it"
relaxation (see above) also makes the workaround lighter: cross-clause
agreement is only enforced at parameter positions a contract actually
references.

## How do I bind names inside `~>` or `or`?

`where` and `whenever` are recognised at the **start** of a contract. They
can't appear inside a larger expression:

```elixir
# does not compile
@post valid: result ~> where(%{"startFrame" => s, "endFrame" => e} = instr,
                             s_ok: is_integer(s) and s >= 0,
                             e_ok: is_integer(e) and e > 0 and e != s)
```

Every case this comes up in is expressible today, usually more clearly.
Pick whichever of these three fits.

**`match?/2` takes a guard.** If the condition on the bound names is
guard-expressible, this is the whole answer — no binding form needed:

```elixir
@post shape: match?({:ok, :cleared}, result) or
               match?({:error, :validation_failed, errs} when is_list(errs), result)
```

**Two assertions, with the antecedent pushed inward.** For the `~>` case,
split the shape requirement from the constraints on the bound names, and
move the antecedent into each scoped assertion. The antecedent is in scope
at the top level, so this always works:

```elixir
@post shape: result ~> match?(%{"startFrame" => _, "endFrame" => _}, instr)
@post whenever(%{"startFrame" => s, "endFrame" => e} <- instr),
      s_ok: result ~> (is_integer(s) and s >= 0),
      e_ok: result ~> (is_integer(e) and e > 0 and e != s)
```

This is equivalent to the version that doesn't compile, and it keeps the
per-assertion labels: a bad `endFrame` reports `label: :e_ok`, and a
result of `true` with the wrong shape reports `label: :shape`.

**A private predicate, for a choice between shapes.** When the alternatives
each need their own bindings and the conditions aren't guard-expressible,
a multi-clause function says it best — and it's independently testable:

```elixir
defp acceptable?({:ok, path}), do: String.starts_with?(path, "/")
defp acceptable?({:error, :validation, errs}), do: Enum.all?(errs, &is_binary/1)
defp acceptable?(_), do: false

@post shape: acceptable?(result)
```

The failure names the predicate and shows the offending value in the
binding, so you still see what went wrong:

```
postcondition failed in MyMod.run/1
|   label: :shape
|   assertion: acceptable?(result)
|   binding: [result: {:ok, "rel"}]
```

The one thing this last form gives up is knowing *which* alternative you
meant to satisfy. If that matters, name the branches with separate
predicates and combine them with `or`.

> #### Why not make `where` composable? {: .info}
>
> Bond deliberately doesn't support these forms as boolean sub-expressions.
> A nested `where` would have to evaluate to `false` on a shape mismatch
> rather than raise — otherwise the left branch of an `or` would blow up
> before the right one was tried — so the same keyword would fail two
> different ways depending on where it appeared. Given that every case
> above is already expressible, that wasn't a trade worth making.

## How do I reuse a predicate across several functions?

If the same condition guards an argument in several functions, you don't
have to retype the expression each time. Contract expressions are ordinary
Elixir, so the simplest reuse is to **define the predicate as a function**
and call it from each contract:

```elixir
defmodule Mailer do
  use Bond

  @pre valid_recipient: valid_email?(to)
  def send_welcome(to, name), do: ...

  @pre valid_recipient: valid_email?(to)
  def unsubscribe(to), do: ...

  # The reusable predicate — declared once, called from any contract.
  # Public on purpose: see below.
  def valid_email?(address) do
    is_binary(address) and String.contains?(address, "@")
  end
end
```

Note that `valid_email?/1` is a `def`, not a `defp`, and that is deliberate.
Bond will happily resolve a private predicate — the checks run in the same
module — but a public function's precondition should not depend on one. Meyer
states the rule directly (*Object-Oriented Software Construction*, 2nd edition,
§11.7, p. 358):

> **Precondition Availability rule**
>
> Every feature appearing in the precondition of a routine must be available to
> every client to which the routine is available.

A precondition is an obligation on the *caller*. A caller that cannot evaluate
it cannot discharge it, so what you have is no longer an agreement — it is a
demand the other party has no way to check.

In Elixir the consequence is visible in your published documentation. Bond
renders the assertion source into the docs for `send_welcome/2`, so a `defp`
predicate produces this:

```
Preconditions
  valid_recipient: valid_email?(to)
```

`valid_email?/1` is private, so it is excluded from the generated docs and
cannot be called. The obligation is published in terms the reader cannot look
up, let alone satisfy. Keep the predicate public when the function it constrains
is public; a `defp` predicate is fine on a `defp`'s own contract, where the only
clients are in the same module.

**Postconditions are exempt**, and Meyer says so directly: "There is no such rule
for postconditions. It is not an error for some clauses of a postcondition clause
to refer to secret features." A postcondition is the function's promise, not the
caller's obligation, so it may reference private helpers freely — it is simply
stating a property the caller cannot verify independently.

Worth noting what Meyer does with this rule that Bond currently doesn't: in
Eiffel it is a *language* rule, a compile-time error, on the grounds that "a
methodological principle does not suffice: we need a language rule to be
enforced by compilers, not left to the decision of developers." Bond accepts a
private predicate silently. Unlike the guard case above, this one is statically
decidable — Bond knows which functions are public — so it is a plausible future
warning rather than a permanent matter of taste.

On failure the error reports the **call**, not the expanded body:

```
label: :valid_recipient
assertion: valid_email?(to)
```

> #### A predicate used in a contract has its own contracts suppressed {: .warning}
>
> Contracts on `valid_email?/1` itself will **not** be evaluated when it is called from
> inside another contract — that is the
> [Assertion Evaluation rule](#are-contracts-evaluated-on-the-recursion-path) at work,
> and it applies to your predicate too. A `@pre` on `valid_email?/1` fires for direct
> calls and is silently inert in the place you most wanted it.
>
> So the reusable predicate has to carry its own weight: keep it simple enough to be
> obviously correct, and test it directly rather than relying on contracts to police it.
> Meyer sets the same bar — functions used in assertions "must be simple and of
> unimpeachable correctness", because by the time one runs, it is too late to ask whether
> it is trustworthy.

That named form is exactly what you want when the predicate is gnarly (a
real email regex reads worse than `valid_email?`). When you'd rather see
the **full expanded expression** in errors and docs — and abstract the
*label* along with it — reach for a macro instead.

### Abstracting the label, and inlining the expanded source

Bond renders an assertion by running `Macro.to_string/1` on the surface
AST you wrote, **without macro-expanding it first**. So a macro *call*
inside `@pre` prints as the call (the named form above). To make the
expanded expression show up, write a macro that **emits the whole labelled
`@pre`**:

```elixir
defmodule Contracts do
  use Bond  # <-- required; see the caveat below

  defmacro require_email(name) do
    var = Macro.var(name, nil)

    quote do
      @pre valid_recipient:
             is_binary(unquote(var)) and String.contains?(unquote(var), "@")
    end
  end
end

defmodule Mailer do
  use Bond
  require Contracts

  Contracts.require_email(:email)   # one line per function
  def send(email), do: email
end
```

Now both the label and the expression are abstracted into one reusable
macro, and the error reports the fully expanded contract:

```
label: :valid_recipient
assertion: is_binary(email) and String.contains?(email, "@")
binding: [email: "nope"]
```

The generated `## Contracts` documentation uses the same captured string,
so it shows the expanded expression too. A single macro can emit several
`@pre`/`@post` lines, which lets you abstract over a *group* of labelled
predicates at once.

### First-class: a named contract with `defcontract`

When the thing you want to share is a *whole agreement* — several
`@pre`/`@post` that always travel together — `defcontract` is the
first-class form of the macro pattern above. Declare it once, apply it with
`@apply_contract`:

```elixir
defcontract recipient(to) do
  @pre valid: is_binary(to) and String.contains?(to, "@")
end

@apply_contract :recipient
def send(email), do: email
```

Unlike a hand-rolled macro, a named contract validates its references at
definition time, binds to the function **positionally** (so it isn't tied to
one parameter name), and attributes failures to the contract by name
(`from contract :recipient`). It can also live in another module and be
applied as `@apply_contract {Contracts, :recipient}`. See the
[Reusable Contracts](reusable-contracts.md) guide. Reach for a
macro instead only when the assertions must be *computed* (the example above
varies the variable name); reach for `defcontract` to share a fixed bundle.

### Caveat: the predicate macro's module must `use Bond`

This is macro hygiene. The `@` inside `Contracts`'s `quote` resolves in
`Contracts`'s context — so if that module doesn't `use Bond`, its `@pre`
is plain `Kernel.@/1`, which treats `@pre <expr>` as a module-attribute
assignment and *eagerly evaluates* the right-hand side. The symptom is a
compile error like `undefined variable "email"`. Add `use Bond` to the
module that defines the predicate macros and `@pre` resolves to Bond's
override, deferring the expression into the generated check as intended.
(You don't need `var!` — `Macro.var(name, nil)` unifies with the function
parameter on its own.)

## How do I share one contract across every implementation of a behaviour?

Declare the contract on the behaviour's `@callback` with `Bond.Behaviour`,
and have implementers inherit it with `use Bond, behaviours: […]`:

```elixir
defmodule Ledger do
  use Bond.Behaviour

  @pre positive_amount: amount > 0
  @post non_negative: result >= 0
  @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
end

defmodule BankAccount do
  use Bond, behaviours: [Ledger]

  @impl true
  def withdraw(bal, amt) when amt <= bal, do: bal - amt
end
```

Every implementation enforces the same `@pre`/`@post` without restating them.
Contracts reference the callback's argument names and bind by position, so an
implementation can name its parameters however it likes. A violation is
attributed to the source behaviour (`precondition (inherited from Ledger)
failed for call to BankAccount.withdraw/2`).

By default an implementation inherits its contracts verbatim, and attaching a
plain `@pre`/`@post` to an inherited operation is a compile error. An
implementation may *deliberately* refine a behaviour's contract with
`@pre_weaken` (weakens the precondition) or `@post_strengthen` (strengthens the
postcondition) — Eiffel-style behavioural subtyping. Protocol implementations
can do the same by adding `use Bond.Protocol.Impl` to the `defimpl` block. In
both flavours, refinement expressions reference the abstraction's canonical
argument names (the callback's or protocol function's), not the implementation's
own parameter names. Use `check/1` in the function body for an
implementation-specific assertion independent of the contract. See the
[Contract Inheritance](contract-inheritance.md#refining-a-contract-pre_weaken-post_strengthen)
guide for the full rules.

> #### Behaviour-level invariants {: .info}
>
> This applies to `@pre`/`@post` on `@callback`s. Struct `@invariant`s remain
> scoped to the struct's own module and compose with inherited contracts
> independently.

## Why didn't my `@post_strengthen` fire — the violation blames a different function?

Because some contract closer to the value caught it first. Bond contracts
compose and are *fail-fast*: each function enforces its own `@pre`/`@post`, and
the first one to fail raises and short-circuits everything after it. For the
**postconditions of nested calls**, the inner callee returns — and its `@post`
is checked — before control returns to the outer function, so an inner
postcondition runs *before* an outer `@post`/`@post_strengthen`:

```elixir
defmodule CognitoSource do
  use Bond, behaviours: [TokenSource]   # callback: fetch(source) :: Token.t

  # Strengthens the inherited @post to also require a non-empty token and positive TTL.
  @impl true
  @post_strengthen non_empty_positive: result.access_token != "" and result.expires_in > 0
  def fetch(source) do
    %Token{access_token: raw_token(source), expires_in: normalize_expires_in(raw_ttl(source))}
  end

  @post positive_integer: result > 0
  defp normalize_expires_in(ttl), do: max(ttl, 0)
end
```

Feeding a `ttl` of `0` here does **not** trip `:non_empty_positive` — it trips
`normalize_expires_in/1`'s own `@post positive_integer`, because that private
function returns (and is checked) first. To exercise the refinement, use a value
that satisfies every inner contract but fails the strengthened rule — e.g. an
empty `access_token`, which has the right *shape* but fails the *non-empty* check
in `fetch/1`'s strengthened postcondition.

This is not refinement-specific — it's how layered contracts have always
composed. Note the asymmetry: **preconditions** are checked outer-first (the
caller's `@pre` runs before the inner call is made), **postconditions**
inner-first. When debugging a refinement that seems inert, check whether an inner
contract is rejecting the value before it ever reaches the outer one.

(The same composition holds for a protocol implementation refining via
`use Bond.Protocol.Impl`; just note that a plain `@post` on a private helper is
only enforced in a module that does `use Bond` — `Bond.Protocol.Impl` installs
the refinement hooks only, not the ordinary `@pre`/`@post` machinery.)

## Why does my nested `forall` report the row instead of the failing inner element?

The `forall`/`exists` quantifiers (see the
[Quantified assertions](getting-started.md#quantified-assertions) guide) capture
the offending element through a single per-process side channel that Bond reads
when the assertion fails. That channel holds **one** failure at a time, so when
quantifiers nest, the *outermost* (last-evaluated) failure wins:

```elixir
@pre all_positive: forall(row <- matrix, forall(c <- row, c > 0))
```

Given `[[1, 2], [3, -4]]`, the inner `forall` records `-4`, but then the outer
`forall` sees that row fail and overwrites the detail with the row itself:

```
|   counterexample: element at index 1 ([3, -4]) does not satisfy `forall(c <- row, c > 0)`
```

The **truthy/falsy verdict is always correct** — only the element-level
`counterexample:` line is best-effort under nesting. The same applies when two
quantifiers sit side by side in one assertion (e.g. joined by `and`): the line
reflects whichever ran last. For a single, bare quantifier — the common case —
the reported element and index are exact.

If you need the precise inner element, split the check into a named inner
predicate or assert the inner `forall` on its own (for example in a `@pre` over
each row in a multi-clause helper), so each quantifier owns its own failure
message.

## Can I use `forall`/`exists` on a stream or a very large collection?

A quantifier enumerates the collection (once, short-circuiting at the first
violation or witness). That's fine for a bounded, materialised collection — a
list, map, `MapSet`, or finite range — but there are three cases to watch, and
Bond deliberately leaves them to you rather than second-guessing your
enumerable at runtime:

**Large collections.** The traversal is `O(n)` on every contracted call, just
like `Enum.all?/2`. If that's too much on a hot path, disable the kind in
production with the runtime gate — `config :bond, postconditions: false` or
`Bond.Config.disable/1` — so it never runs there. (See
[Will contracts slow down my production code?](#will-contracts-slow-down-my-production-code)
above.)

**Effectful streams — don't.** Bond assertions must be side-effect-free, and
*enumerating a lazy stream is a side effect*. A `@post` that quantifies over a
stream `result` (or a `@pre` over a stream argument) enumerates it to check the
predicate:

```elixir
# DON'T: the @post enumerates `result`, advancing/consuming the stream
@post nonempty_lines: forall(line <- result, line != "")
def read_lines(path), do: File.stream!(path)
```

For a **pure, re-enumerable** stream this merely doubles the work (the stream
runs once for the contract and again for the caller). For a stream over a
**one-shot or effectful source** — stdin via `IO.stream/2`, an
`Ecto.Repo.stream` cursor, a socket — the contract's enumeration consumes or
re-fires the resource, corrupting what the caller gets. If the producer is
finite and pure and you genuinely want to assert over it, materialise it at the
call site:

```elixir
# OK: enumeration is explicit, happens once, and the cost is visible
@post nonempty_lines: forall(line <- result, line != "")
def read_lines(path), do: File.read!(path) |> String.split("\n")
```

**Infinite streams — never.** `forall` returns only when an element *fails* and
`exists` only when one *succeeds*, so an all-passing `forall` (or no-match
`exists`) over `Stream.cycle/1` / `Stream.iterate/2` never terminates. A finite
and an infinite stream share the same type, so Bond can't catch this for you —
quantify only over bounded collections.
