# Writing Sound Assertions

A Bond assertion is ordinary Elixir, evaluated for truthiness at runtime. That is the
source of its power — you have the whole language, plus Bond's
[predicate vocabulary](`Bond.Predicates`) (`<~`, `~>`, `forall`/`exists`, `xor`, `|||`)
— and also its one sharp edge: **nothing type-checks your assertion**. An expression
that is always true, always crashes, or means something other than it reads will compile,
run, and often *pass*, telling you nothing while looking like coverage.

That is worse than no contract at all. A missing contract is honestly silent; a vacuous
one lies. The goal of this guide is to help you write assertions that *can fail on the
input they are meant to reject* — and to recognise the handful of constructs whose surface
reading does not match their behaviour.

> #### The one habit that prevents most of these {: .tip}
>
> For every non-trivial assertion, prove it can fail: feed it an input that *should*
> violate it and confirm it raises, with a `Bond.Test` assertion that names the clause.
> See [Asserting a contract is violated](testing-contracts.md#example-based-testing-with-bond-test).
> An assertion you have never seen fail is an assertion you have not tested.

## Surface-misleading operators

### `|||` is exclusive-or, not "or"

`Bond.Predicates.|||/2` is `xor`, despite reading like a logical *or*. The two differ
exactly when both operands are true:

```elixir
# "if keys remain, a timer is armed" — the intended meaning is OR
Enum.empty?(remaining) or is_reference(timer)        # ✅ says what it means

Enum.empty?(remaining) ||| is_reference(timer)       # ❌ XOR: also fails when BOTH are true
```

Use `or` for disjunction, `xor`/`|||` only when you genuinely mean "exactly one", and
`~>` (`p ~> q`, "p implies q") for the very common "if this shape, then that property".
`~>` is also the safe choice when the consequent only makes sense once the antecedent
holds — it short-circuits instead of evaluating a consequent that would raise.

## Comparisons that are silently constant

Bond does not know the *types* of the things you compare. A comparison between values that
can never be equal is a constant — and a constant assertion never fires:

```elixir
# `key` is a string; `remaining_keys` is a list of maps. A string is never a member of a
# list of maps, so this is ALWAYS true and asserts nothing.
forall(%{key: key} <- entries, key not in remaining_keys)     # ❌ vacuously true
```

`==`, `!=`, `in`, and `not in` across type-disjoint operands are the usual culprits. When
you write one, sanity-check that the two sides *could* actually be equal — and prove it by
watching the assertion fail once (see the tip above). The same caution applies to
comparing a value against a literal of the wrong type (`status == 200` when `status` is
`:ok`).

## The assertion linter catches the obvious cases

Bond runs a small **compile-time linter** over every assertion and emits a warning for the
high-confidence, provably-constant smells — so some of the traps in this guide are caught for
you the moment you compile:

- **Constant assertions** — an expression that folds to a constant over literals and pure
  operators: `:ok == 200`, `"x" not in [%{...}]`, `1 == 1`.
- **Self-comparisons** — `x == x` (always true), `x != x` (always false), `p or not p`.
- **Vacuous quantifiers** — a `forall`/`exists` with a bare-variable generator and a predicate
  that is constant or never mentions the element: `forall(x <- items, true)`.

It is deliberately narrow: it only warns when it can *prove* the assertion is constant, because
a noisy contract linter gets turned off wholesale. In particular it **cannot** catch the
type-disjoint comparison above (`key not in remaining_keys`) — knowing `remaining_keys` holds
maps requires type inference Bond does not do without Dialyzer. That class stays your
responsibility, which is why the "prove it can fail once" habit still matters. (Watching an
assertion that never fails is also the job of contract-coverage tooling — the dynamic complement
to this static check.)

To silence it — e.g. for a deliberate placeholder assertion — disable it globally:

```elixir
# config/config.exs
config :bond, lint_assertions: false
```

## Quantifier generators bind and assert shape — they do not filter

`forall`/`exists` use a comprehension-*looking* generator, `pattern <- enumerable`, but the
pattern **binds, it does not filter**. A `for` comprehension *skips* an element that does not
match; a Bond quantifier does the opposite — a **structural** generator pattern makes a
non-matching element **fail the assertion**, with a clean counterexample that names the
unmatched pattern. The destructuring generator therefore doubles as a shape assertion:

```elixir
# binds `retry` from each entry and asserts a property of it; an entry missing `:retry`
# fails the contract, naming the element — it is not silently skipped
forall(%{retry: r} <- entries, r >= 0)
```

A **bare-variable** generator (`forall(x <- xs, …)`) matches every element, so there is no
shape to violate — the predicate does all the work.

To assert a property of *only* the elements of a given shape while **ignoring** the rest
(comprehension-style filtering), guard the predicate with `~>` so non-matching elements pass
vacuously:

```elixir
forall(entry <- entries, match?(%{retry: _}, entry) ~> entry.retry >= 0)
```

This is the same discipline as shape-dependent predicates in multi-clause contracts: when a
predicate only makes sense for some inputs, gate it with `~>`.

## `old/1` is meaningful only for state that changes

`old(expr)` snapshots a value at function entry so a `@post` can compare entry and exit.
For an immutable parameter `x`, `old(x)` and `x` are the same value, so `old(x) == x` is a
tautology — a sign you meant to snapshot something that actually mutates (a field reachable
through shared state, the process dictionary, an ETS table). See
[Contracts in a Concurrent World](contracts-and-concurrency.md) for `old/1`'s semantics and
the concurrency caveats around snapshotting shared state.

## Prefer fail-fast shapes to clever ones

A few smaller habits keep assertions honest:

  * **Label your assertions.** A labelled clause (`positive: x > 0`) names what it checks in
    the failure message and lets a test target *that* clause by `label:`. An unlabelled wall
    of `and`s fails as one opaque expression.
  * **One claim per assertion.** Splitting `a and b and c` into three labelled assertions
    turns one ambiguous failure into a precise one, and makes each individually testable.
  * **Keep predicates total where you can.** A predicate that pattern-matches or calls a
    partial function can raise instead of returning `false`; gate it with `~>` so a
    non-applicable input is *vacuously satisfied* rather than a crash.

## What Bond checks for you, and what it doesn't

Bond validates the *structure* of your contracts at compile time — that a contract
references only in-scope names, that `@pre`/`@post` take a single argument, that quantifiers
have one generator and one predicate, and so on. It does **not** evaluate the *truth* of your
assertions ahead of time, because they are arbitrary runtime expressions. The pitfalls above
are the ones a type checker would catch in a typed contract language; in Bond, a little
discipline (and one failing test per assertion) stands in for that checker.

A future Bond release may flag a high-confidence subset of these — provably-constant
comparisons, quantifiers whose body ignores their binding — as compile-time warnings or a
Credo check. Until then, this guide is the checklist.

## See also

  * `Bond.Predicates` — the full reference for `<~`, `~>`, `forall`/`exists`, `xor`, `|||`,
    and friends, including the operator-precedence notes.
  * [Testing Contracts](testing-contracts.md) — proving an assertion fires (and holds) with
    `Bond.Test` and `Bond.PropertyTest`.
  * [Contracts in a Concurrent World](contracts-and-concurrency.md) — `old/1` semantics and
    snapshotting shared state safely.
