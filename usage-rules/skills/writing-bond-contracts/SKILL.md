---
name: writing-bond-contracts
description: "Decide what a Bond contract should SAY — not the syntax, the content. Load when adding or reviewing a @pre / @post / @invariant / @state_invariant, when a Bond.Coverage row reads `⚠ never failed`, when asked whether a function needs a contract, or when a contract seems to assert nothing. Complements the bond usage rules, which cover mechanics."
---

# Writing Bond contracts that say something

Bond gives you the syntax and no opinion about what to put in it. This is that opinion. For
mechanics — the traps, the operators, configuration — see the `bond` usage rules.

## Start here: a contract is a specification

It states what a function or a type **promises**, in terms a caller can rely on, checked by
machine and published in your ExDoc. Catching bugs is what a specification does when the
implementation disagrees with it — a consequence worth having, not the purpose.

This is not academic. It changes which contracts get written, because the two frames disagree
about a whole class of them, and the bug-catching frame deletes correct specifications.

## The test is mechanism versus meaning

Not "does it restate the body". For a short function the answer is often yes and the contract is
still worth having.

```elixir
# ❌ Mechanism. The implementation, spelled twice.
@post mapped: result == Enum.map(xs, &transform/1)
def process(xs), do: Enum.map(xs, &transform/1)

# ✅ Meaning. Fits on one line, but it is a claim about the result,
#    not a recipe for producing it.
@post definition: result == (stack.count == stack.capacity)
def full?(%Stack{} = stack), do: stack.count == stack.capacity
```

The first names the algorithm. Rewrite the body as a `for` comprehension and you must edit the
assertion in the same commit, because the assertion *is* the implementation.

The second names a property, and survives any correct rewrite — which is precisely what a
specification is for. Meyer's answer to "but a plausible rewrite could never violate it" is that
the body could equally have been `if count == capacity, do: true, else: false`, and the
postcondition is what says those are the same function. *The instruction is prescriptive; the
assertion is descriptive* (OOSC §11.7, p. 352).

**Sharpening:** if you cannot describe the assertion without describing how the function works,
it is mechanism.

The resemblance is an artefact of trivial bodies. Meyer's own next example is a square root,
whose postcondition is `abs(result * result - x) <= tolerance` — nothing about which looks like
an algorithm for computing square roots. That is the normal case; `full?` is the degenerate one.

`@post computed: result == a + b` beside `def add(a, b), do: a + b` is best described not as a
restatement but as **degenerate**: for `add/2`, `+` genuinely is the meaning, and the `@spec` and
the name already carry it. Leave it out — but not because it looks like the body.

## The three questions

**What must the caller guarantee for this call to make sense?** → `@pre`. Not "what would crash
the body" — what the *specification* requires. A precondition you cannot justify from the
function's stated purpose is the implementer's convenience leaking into the interface.

**What does this function promise in return?** → `@post`. State it as a property of `result`, of
the arguments, and of `old(...)` state where something changed. If the honest answer is "whatever
the body computes", say nothing.

**What is always true of this value, between calls?** → `@invariant`. It belongs to the type, not
to any one function.

## The quality check: can this assertion fail?

Falsifiability is not *why* you write a contract. It is the sharpest check on whether you wrote a
good one, because an assertion that can never fail usually describes mechanism rather than
meaning. A vacuous contract is worse than none — it *looks* like coverage.

Treat "this cannot fail" as a question with three answers, only one of which is "delete it":

| Why it cannot fail | What to do |
| --- | --- |
| It transcribes *how* the body works | Restate it as *what* the function promises |
| The body guards the property twice | **Delete the redundant guard**, keep the contract |
| It is a true law of a pure function, unfalsifiable by data | Keep it — prove it by mutation |

The second is easy to misread. One real case: a `no_empty_names` postcondition would not fire
under any single edit, because the body both passed `trim: true` *and* ran an explicit
`Enum.reject(&(&1 == ""))`. Only a double mutation could falsify it. The fix was deleting the
redundant guard, not weakening the contract — after which a single plausible edit failed loudly.

The third is the common case for specifications and is **not** a defect. A pure function's
postconditions are *production* assertions: they hold over every input the application ever sees,
which is the point. Measured on one normalization function: 128,992 codepoints, ~387,000 inputs,
**zero violations** — and the contract still earns its place, because it is the single point every
provider's strings pass through, and "is normalization why this user's matches are bad?" becomes
answerable from a remote console instead of a rebuild.

**Mutation is how you prove that class.** Break the implementation deliberately, confirm the
assertion fires, restore. Two minutes, and it is the only thing that distinguishes
unbreakable-by-correct-code from unbreakable-because-vacuous.

## Shapes that pay off

The full catalogue with worked examples is in `references/contract-shapes.md`. In brief, look for:

  * **One rule written twice.** A query and a predicate, a database constraint and a changeset
    validation, a serializer and its parser. Nothing keeps them in step, and drift is silent in
    both directions. Assert that they agree — this is consistently the strongest contract in a
    codebase.
  * **Conservation.** Nothing invented, nothing lost: `forall(x <- result, x.id in input_ids)`,
    `length(result) <= length(input)`, `matched + unmatched + skipped == total`.
  * **Two accumulations of one truth, cross-checked before a write.** Where a fold happens twice —
    once into counters, once into rows — nothing holds the two in step, and a mismatch produces a
    summary and a report that disagree while neither looks wrong.
  * **Relationships that still "work" when broken.** A PKCE flow that sends the verifier where the
    challenge belongs still completes, still passes every test, and has lost all its protection.
  * **Units and magnitudes that are not type errors.** `@pre skew_under_a_day: skew <= 86_400`
    catches milliseconds passed as seconds — nothing fails, the system just hammers the provider.
  * **Values that are silently poisonous downstream.** ISO 8601 admits negative durations; a
    negative duration is not a shorter track, it is a value that scores as a near miss in a
    matching engine.

## Where a law goes: who can be at fault?

A precondition violation is a bug in the **caller**; a postcondition or invariant violation is a
bug in the **function** (Meyer's Assertion Violation rule). That answers "where does this
assertion belong?".

Worked case: `Catalogue.album_id/3` requires `barcode == Barcode.normalize(barcode)`. A
non-idempotent `normalize/1` makes that precondition **unsatisfiable**, and it fires as a
*precondition* violation — blaming a client that normalized exactly once, as instructed, and had
no way to do better. Adding `@post idempotent: normalize(result) == result` to `normalize/1`
names the supplier at the point of production, before the value ever travels.

**A law about a function's own output belongs on that function**, even when a caller's
precondition would happen to trip over the violation first.

Two corollaries:

  * **Lift a law to an `@invariant` when it is a property of the type** rather than of one call —
    it then holds for every instance however constructed, including ones built in fixtures.
  * **When you add a precondition, audit its call sites.** Making an obligation explicit does not
    discharge it. One real case: adding a non-blank-token precondition turned a reachable `""` —
    written to the database before the invariant existed — into a crash in a transfer, where it
    should have told the user to reconnect. A contract does not retroactively clean a database.

## Check independence, don't assume it

Two assertions on one function are fine when **neither can see the other's bug**. The test is not
"are there two" but "can a single plausible edit or input falsify each independently".

Worked case: `threshold/1` carries a `@pre` and a `@post` that look redundant. A percentage (`75`)
passes the precondition's `is_number/1` and is caught by the postcondition's range check. A typo
(`:hgih`) fails the precondition's known-confidence check but resolves through a default to `1.0`,
which is a perfectly valid proportion the postcondition waves through. Both real, both needed.

The mirror case: an assertion that only *looks* implied by its neighbour. A shape assertion
("the result is a leading-zero-free digit string") does not imply idempotence — an edit that
sliced off a check digit satisfies the shape at every step, and only idempotence notices. **The
tell is that they say different kinds of thing:** one describes the *shape of the output*, the
other the *character of the function*. Assertions on different dimensions want checking, not
eliminating by inspection.

Where two genuinely do coincide, keep the stronger one and drop the other.

## What not to assert

  * **Types.** Use `@spec` — rendered more prominently, checked by Dialyzer, free at runtime.
    Exception: when violating it produces a *confusing crash somewhere else*, a `@pre` converts
    that into a named violation identifying the caller.
  * **What a guard already enforces.** The guard raises `FunctionClauseError` first, so the
    assertion is unreachable. A `@pre` *stronger* than the guard can fail and is worth keeping.
  * **That external data was well formed.** A contract guards *your* logic. A provider sending
    nonsense is not a programming error, and a `@post` that raises on it converts their bad data
    into your crash. **At a parsing boundary, assert what you emit, never what you received.** If
    an assertion about emitted data fires against real input, the fix is usually to sanitize the
    value — after which the same assertion becomes a law about what you produce, which is the only
    thing you control.
  * **Anything about a lazy stream.** Asserting over one consumes it. Contract the eager thing
    next to it.
  * **Anything about shared mutable state.** See below.
  * **Anything unfalsifiable in this codebase.** Requiring a `DateTime` be UTC looks principled,
    but if no call site can construct a non-UTC one, nothing is being checked — and with a
    timezone database in play the assertion would reject *valid* calls. **Falsifiable is not the
    same as valuable:** an assertion should reject inputs that are wrong, not merely unconventional.
  * **Uniqueness, when duplicates are legal in the domain.** A ledger law written as "no track
    reported twice" fires on the first correct input containing a genuine duplicate. Compare
    **multisets** against the input instead — `Enum.sort(out) == Enum.sort(in)` — which is sound,
    strictly stronger, and rejects a drop, a duplication *and* a substitution.
  * **Anything on dead code.** An assertion that never executes is worse than one that never
    fails: it does not even appear in the coverage table. **Check for callers first** — an
    uncontracted function nothing calls is a question about the design, and answering it is a
    prerequisite to contracting it.

## Shared state: assert only what survives interleaving

If another process can write between an `old/1` snapshot and the check, the assertion **accuses
correct code** — the worst failure a contract can have, because it teaches you to distrust the
contract rather than the program.

```elixir
@post removed_exactly_one_row: count() == old(count()) - 1        # ❌ races
@post removed_what_was_asked_for: removed.user_id == user_id      # ✅ race-free
```

Under concurrent writes, *nothing* about a global count is assertable. **The strong law belongs in
a test**, where a sandbox makes the state exclusive — or in a `GenServer`, where callbacks are
serialized and a `@transition_invariant` can say "this changes by at most one per message" sound
ly. Two things follow:

  * **"It is off in production" is not a licence to write an unsound assertion.** Anyone can
    switch it on.
  * A `Bond.Server` invariant violation raises inside the server, the supervisor restarts it, and
    **the suite can report all green**. That is the argument *for* process invariants — it is a bug
    tests structurally cannot see — but it makes them a **diagnostic, not a gate**.

## Demanding or tolerant?

Meyer names two attitudes and marks the choice as judgement rather than law. Elixir needs a
three-way distinction where Eiffel needs two:

1. **Demand it.** `@pre non_empty: items != []`. A violation is a bug in the caller.
2. **Return it.** `{:error, :empty}`. The function reports; the *caller still decides*.
3. **Guess.** Log something, return `nil`, substitute a default.

Only (3) is what Meyer attacks. Idiomatic `{:ok, _} | {:error, _}` is **not** the tolerant style
he warns about — it delegates the decision rather than making it. "Prefer demanding" means prefer
(1) or (2) over (3), never "stop returning error tuples".

Choose between (1) and (2) by asking what a violation *is*. If reaching this state means somebody
upstream has a bug, it is a precondition. If a correct caller with valid data can legitimately
land here, it is a normal outcome and belongs in the return value. Bond sharpens it: **a
precondition can be purged and an `{:error, _}` cannot**, so anything a running system must still
handle with contracts compiled out has to be (2).

Modules facing the outside world — HTTP clients, provider adapters, parsers — are **filters** and
should be tolerant. The domain behind them is demanding. The seam is precise: **the postconditions
of the filter modules must match or exceed the preconditions of the processing modules.**

And bound the demanding style — `require False` makes every routine trivially correct. Meyer's
**Reasonable Precondition principle**: it must appear in the documentation clients read (Bond gives
you this free), and it must be justifiable **from the specification alone**. "There is no maximum
of an empty collection" justifies `@pre non_empty` on `max/1`. "My implementation calls
`Map.get/2`" does not justify `@pre is_map(opts)` — that is an implementation detail leaking into
the caller's obligations, and the day you switch to a keyword list the caller's contract changes
for no reason the caller can see.

## Two structural smells

**Several `@bond_warn_skipped_invariants false` in one module usually means it holds two
abstractions.** One real case had four suppressions, all about a *scale* while the struct was one
item graded by it — different lifetimes, so splitting the scale into its own module removed every
suppression and gave it contracts it could not have had while hiding in a struct module. That split
also exposed a live bug the arrangement had kept invisible. A suppression without a reason written
beside it is the one to go back to.

**A duplicated private helper is a missing module, and the module is where the contract goes.**
Don't extract it to whichever caller seems closer — ask what boundary both callers are standing at
and name *that*. Then name the abstraction **for the value, not the guard**: `count/1`, not
`non_negative_integer/1`. The postcondition can carry the check without the name repeating it.

## Checklist for a new contract

1. **State what the function or type promises**, in terms a caller can rely on. If you cannot say
   it, you do not understand the thing well enough to contract it yet.
2. **Meaning or mechanism?** Mechanism goes in the body. "It resembles the body" is not the test.
3. **Is it a type check?** Then `@spec` — unless violating it crashes confusingly elsewhere.
4. **Is it total?** Lead with a type check; gate partial predicates with `~>`.
5. **Is it available to the caller?** A `@pre` naming a `defp` (or a `@doc false` function) is one
   the client cannot discharge.
6. **Justifiable from the specification alone**, or only from how you happened to implement it?
7. **Can it fail?** Write a `Bond.Test` assertion targeting its `label:`. Where no input can
   falsify it, mutate the implementation and confirm it fires.
8. **Read the coverage table.** `⚠ never failed` is a question with three answers.
9. **When you add a precondition, audit its call sites.**
