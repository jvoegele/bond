# Writing Sound Assertions

A Bond assertion is ordinary Elixir, evaluated for truthiness at runtime. That is the
source of its power — you have the whole language, plus Bond's
[predicate vocabulary](`Bond.Predicates`) (`<~`, `~>`, `forall`/`exists`, `xor/2`, `|||`)
— and also its one sharp edge: **nothing type-checks your assertion**. An expression
that is always true, always crashes, or means something other than it reads will compile,
run, and often *pass*, telling you nothing while looking like coverage.

That is worse than no contract at all. A missing contract is honestly silent; a vacuous
one lies. The goal of this guide is to help you write assertions that *can fail on the
input they are meant to reject* — and to recognise the handful of constructs whose surface
reading does not match their behaviour.

> #### This guide is the quality check, not the purpose {: .info}
>
> Falsifiability is how you check an assertion is *good*. Stating the specification is
> *why* you write one. Both matter, and they are different tests — applied as though it
> were the second, the first will talk you out of correct specifications.
> [What Should a Contract Say?](what-contracts-say.md) covers the other half, and is
> worth reading first if you have not.

> #### The one habit that prevents most of these {: .tip}
>
> For every non-trivial assertion, prove it can fail: feed it an input that *should*
> violate it and confirm it raises, with a `Bond.Test` assertion that names the clause.
> See [Asserting a contract is violated](testing-contracts.md#example-based-testing-with-bond-test).
> An assertion you have never seen fail is an assertion you have not tested.

## Assertions must be total, not merely side-effect-free

An assertion has to return a truthy or falsy value for *every* input it can see.
One that raises instead has not been shown to hold or to fail — it could not be
evaluated at all.

```elixir
@pre valid: String.contains?(email, "@")
def normalize(email), do: String.downcase(email)

normalize(nil)
** (Bond.AssertionEvaluationError) precondition could not be evaluated for call to MyApp.normalize/1
|   label: :valid
|   assertion: String.contains?(email, "@")
|   binding: [email: nil]
|   raised: ** (FunctionClauseError) no function clause matching in String.contains?/2
```

`String.contains?/2` requires a binary, so the precondition is partial: it
answers for strings and raises for everything else. Bond reports this as its own
error rather than as a violation, because "the contract is false" and "the
contract is unevaluable" are different facts and conflating them would hide a bug
in the predicate.

The fix is almost always to lead with a type check, so the assertion is total
over anything that can reach it:

```elixir
@pre valid: is_binary(email) and String.contains?(email, "@")
```

Now `normalize(nil)` raises an ordinary `Bond.PreconditionError` — the contract
did its job.

> #### Why this matters more than it looks {: .warning}
>
> Everywhere else in Bond, turning contracts *on* can only add a `Bond.*Error`
> where the code would otherwise have proceeded. A partial assertion is the one
> exception: it can turn a call that would have worked — or returned a clean
> `{:error, _}` — into a raise, and `:purge` makes it disappear again. That is a
> behavioural difference between your contracted and purged builds, which is
> exactly what contracts are supposed not to introduce.

Common partial predicates to watch for: `String.*` on a possibly-`nil` value,
`length/1` on a non-list, `map_size/1` on a non-map, arithmetic on a
possibly-`nil` field, and `Enum.*` on something that may not be enumerable.

## Surface-misleading operators

### `|||` is exclusive-or, not "or"

`Bond.Predicates.|||/2` is `xor`, despite reading like a logical *or*. The two differ
exactly when both operands are true:

```elixir
# "if keys remain, a timer is armed" — the intended meaning is OR
Enum.empty?(remaining) or is_reference(timer)        # ✅ says what it means

Enum.empty?(remaining) ||| is_reference(timer)       # ❌ XOR: also fails when BOTH are true
```

Use `or` for disjunction, `xor/2` (or its infix alias `|||`) only when you genuinely mean "exactly one", and
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

## A `@post` that transcribes the *mechanism* says nothing

A postcondition earns its keep by describing what the function guarantees. One that
transcribes *how* it computes it asserts only that the code does what the code does:

```elixir
@post computed: result == a + b        # ❌ fails only if `+` is broken
def add(a, b), do: a + b
```

State the property the implementation must obey instead, and the contract survives a
rewrite — which is exactly when you want it:

```elixir
@post conserved: result.from.balance + result.to.balance ==
                   from.balance + to.balance
def transfer(from, to, amount), do: ...
```

That one has no opinion about how the transfer is implemented, and it fails the day someone
adds a fee and takes it out of one side only. A good postcondition is a law the body must
respect, not a second copy of it.

> #### "Does it restate the body?" is the wrong test {: .warning}
>
> The trap is to generalise the `add/2` example into a rule against postconditions that
> *resemble* their implementation, and then delete real specifications for failing it.
>
> ```elixir
> # Resembles the body. Keep it.
> @post definition: result == (stack.count == stack.capacity)
> def full?(%__MODULE__{} = stack), do: stack.count == stack.capacity
> ```
>
> The distinction that holds is **mechanism versus meaning**, not resemblance.
> `result == Enum.map(xs, &f/1)` beside a body that maps names the algorithm;
> `result == (count == capacity)` names a property that happens to fit on one line, and
> still publishes the function's guarantee to every reader of the generated docs.
> Meyer works through this exact case — the instruction is prescriptive, the assertion
> descriptive (§11.7, p. 352). See
> [What Should a Contract Say?](what-contracts-say.md#the-test-is-mechanism-versus-meaning).

## A `@pre` the guard already enforces can never fail

Bond reproduces your `when` guards on the wrapper clauses so multi-clause dispatch keeps
working. An argument that fails the guard therefore raises `FunctionClauseError` *before*
any precondition is evaluated:

```elixir
@pre valid_recipient: is_binary(to)                    # ❌ unreachable
def send_welcome(to, name) when is_binary(to), do: ...
```

`send_welcome(nil, "ana")` raises `FunctionClauseError`, never
`Bond.PreconditionError`. The assertion isn't wrong — it's unreachable, which is the same
problem as a constant assertion arriving by a different route.

The test is the one this guide keeps returning to: **can this assertion fail?** If the
guards already reject everything it rejects, it can't, and it is worth deleting rather
than keeping. A `@pre` that is *stronger* than the guards is a different matter entirely —
it can fail, so it earns its place:

```elixir
@pre even_amount: rem(amount, 2) == 0                  # ✅ reachable
def credit(balance, amount) when is_integer(amount), do: ...
```

The guard admits `3`; the precondition rejects it. "There is a guard" is not by itself a
reason to drop a precondition — "the guard already rejects everything this rejects" is.

### But the contract documents the function and the guard doesn't

True, and it is the strongest argument for keeping both — but it points at `@spec` rather
than at a redundant precondition. ExDoc renders the signature, any `@spec` above it, and
Bond's generated contract sections; the `when` guard appears in none of them. So for a
*type*, a `@spec` puts the fact in the documentation **more** prominently than a `@pre`
would, has Dialyzer check it, and costs nothing at runtime:

```elixir
@spec send_welcome(String.t(), String.t()) :: :ok
def send_welcome(to, name) when is_binary(to) and is_binary(name), do: ...
```

This is Design by Contract's own division, not a workaround: Eiffel states types in the
declared parameter types and keeps `require` for what types cannot say. Reach for `@pre`
when the requirement is one no type can state — a relationship between two arguments, a
domain rule, a condition on a field's value. Those are the ones that can fail, and they
document themselves in the process.

See [Should I remove guards when I add contracts?](faq.md#should-i-remove-guards-and-pattern-matches-when-i-add-contracts)
for the full argument, including Meyer's Non-Redundancy Principle and what to do about a
condition you want enforced even in a purged build.

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
maps requires type inference Bond does not do without Dialyzer. Nor can it catch a precondition
made unreachable by a guard, which needs the same reasoning about what the guard admits. Those
classes stay your responsibility, which is why the "prove it can fail once" habit still matters.
Watching for an assertion that never fails is the dynamic complement to this static check, and
`Bond.Coverage` does it across a whole suite — see
[Contract coverage](testing-contracts.md#contract-coverage-which-assertions-have-you-seen-fail).

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

The high-confidence subset — provably-constant comparisons, quantifiers whose body ignores
their binding — is already caught by the [assertion
linter](#the-assertion-linter-catches-the-obvious-cases) above. Everything that needs to know
a value's *type* stays yours; this guide is the checklist for it.

## See also

  * [What Should a Contract Say?](what-contracts-say.md) — the other half of the
    question: what an assertion should be *stating*, as distinct from whether it can
    fail.
  * `Bond.Predicates` — the full reference for `<~`, `~>`, `forall`/`exists`, `xor`, `|||`,
    and friends, including the operator-precedence notes.
  * [Testing Contracts](testing-contracts.md) — proving an assertion fires (and holds) with
    `Bond.Test` and `Bond.PropertyTest`.
  * [Contracts in a Concurrent World](contracts-and-concurrency.md) — `old/1` semantics and
    snapshotting shared state safely.
