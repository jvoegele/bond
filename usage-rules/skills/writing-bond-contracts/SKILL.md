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

**And it changes how many.** Aim for a contract on every non-trivial function. This skill is a
quality bar on the assertion you are writing, not a gate to argue past before writing one —
almost nothing in it is a reason to leave a function bare. The failure mode is one-sided: a
codebase with too few contracts looks exactly like one that never needed them, so careful
screening under-contracts by default and nobody notices. Measured on an application contracted
with these rules, reaching a density its author was happy with took **five passes**, each earlier
one having stopped too soon. Start from "what does this promise?" and write what you can state.

`mix bond.audit --verbose` names every public function that carries no contract of its own, so
this is measurable rather than a matter of impression — run it before concluding a pass is
finished.

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

**Delegation is mechanism too.** A function whose body hands the work to a collaborator that
already guarantees a property still owes that property to *its own* caller:

```elixir
# The mapper's @post guarantees this. State it here anyway.
@post both_halves_usable: forall(r <- result, usable?(r))
def playlist_item_references(client, id, opts), do: Mapper.references(fetch_pages(client, id, opts))
```

"The callee already checks it" describes how this function is built today, and a refactor can
retire that callee without touching this function's promise. The guarantee renders into *this*
function's ExDoc, and its callers read it there — they have no reason to know the mapper exists.
The same reasoning as `full?`: the delegation is prescriptive, the assertion descriptive.

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
| The body guards the property twice **by accident** | **Delete the redundant guard**, keep the contract |
| Two guards are **independently sufficient** by design | Keep both — mutate them *together* |
| It is a true law of a pure function, unfalsifiable by data | Keep it — prove it by mutation |

The two middle rows look identical from the coverage table and want opposite treatment. Defence
in depth — an application-level scope *and* row-level security under it — is falsifiable only by
removing both, which is the refactor the contract exists to notice. See `bond:testing` for how to
mutate one. It is the same trap as the purge test below, in a different costume: **"redundant" is
a conclusion, not an observation.**

The accidental case is easy to misread. One real case: a `no_empty_names` postcondition would not fire
under any single edit, because the body both passed `trim: true` *and* ran an explicit
`Enum.reject(&(&1 == ""))`. Only a double mutation could falsify it. The fix was deleting the
redundant guard, not weakening the contract — after which a single plausible edit failed loudly.

The last row is the common case for specifications and is **not** a defect. A pure function's
postconditions are *production* assertions: they hold over every input the application ever sees,
which is the point. Measured on one normalization function: 128,992 codepoints, ~387,000 inputs,
**zero violations** — and the contract still earns its place, because it is the single point every
provider's strings pass through, and "is normalization why this user's matches are bad?" becomes
answerable from a remote console instead of a rebuild.

**Mutation is how you prove that class.** Break the implementation deliberately, confirm the
assertion fires, restore. Two minutes, and it is the only thing that distinguishes
unbreakable-by-correct-code from unbreakable-because-vacuous.

**"No current caller violates it" is not a row in that table.** Every row asks whether the
assertion *could* be false for an input the specification admits — never whether today's call
sites produce one. A precondition is a standing obligation on every *future* caller, and callers arrive: the
value of `@pre positive: amount > 0` is that it holds the line the day someone adds a call site
that gets it wrong. Well-behaved callers, even carefully contracted ones, are a reason the
contract will stay green, not a reason to leave it unwritten. Census the call sites to understand
the function; never to decide whether it deserves a contract.

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

Every entry below is here for one of three reasons: the assertion is **unsound** (it can accuse
correct code), **unreachable** (it cannot run), or **not warranted by the specification**. Nothing
is on this list because contracting is costly, because the layer feels unimportant, or because
nothing currently violates it — and if you find yourself declining a contract for a reason that is
not one of the three, the reason is not good enough.

  * **A type, where the type is all you would be saying.** Use `@spec` — rendered more
    prominently, checked by Dialyzer, free at runtime. It is a division of labour, not a ban:
    `@spec` is static and never runs, so where the value arrives from outside the compiler's view
    (parsed input, a provider payload, a message from another process), or where violating it
    produces a *confusing crash somewhere else*, a `@pre` is what actually fires and it names the
    caller. A type check carrying a further constraint is not a type check.
  * **What a guard already enforces.** The guard raises `FunctionClauseError` first, so the
    assertion is unreachable. *Which* side to drop is Meyer's **Non-Redundancy Principle**, and
    only one of three cases is redundant at all: a guard that **selects a clause** is dispatch
    (keep it, no `@pre`); a guard **standing in for a type** is Elixir's declared parameter type
    (keep it, state the fact in `@spec`); a guard **stating a domain rule** —
    `when amount <= account.balance` — is the redundant one, and there you **pick one**. If a
    violation is the caller's bug, that is the `@pre`: write it and drop the guard, since only
    the contract names the caller, reaches the docs, and appears in the coverage table — but
    **apply the purge test first**, because a load-bearing guard cannot be replaced by a `@pre`.
    It is otherwise the trade the falsifiability table names — **delete the redundant guard, keep
    the contract.** A `@pre` *stronger* than the guard is not redundant and stands as it is.
  * **That external data was well formed.** A contract guards *your* logic. A provider sending
    nonsense is not a programming error, and a `@post` that raises on it converts their bad data
    into your crash. **At a parsing boundary, assert what you emit, never what you received.** If
    an assertion about emitted data fires against real input, the fix is usually to sanitize the
    value — after which the same assertion becomes a law about what you produce, which is the only
    thing you control.
  * **Anything about a lazy stream.** Asserting over one consumes it. Contract the eager thing
    next to it.
  * **Anything about shared mutable state.** See below.
  * **Anything the specification does not actually require.** Requiring a `DateTime` be UTC looks
    principled, but with a timezone database in play a non-UTC value is a perfectly good argument,
    so the assertion rejects *valid* calls. **Falsifiable is not the same as valuable:** an
    assertion should reject inputs that are wrong, not merely unconventional. The test is what the
    specification admits — never whether today's call sites happen to pass it.
  * **Uniqueness, when duplicates are legal in the domain.** A ledger law written as "no track
    reported twice" fires on the first correct input containing a genuine duplicate. Compare
    **multisets** against the input instead — `Enum.sort(out) == Enum.sort(in)` — which is sound,
    strictly stronger, and rejects a drop, a duplication *and* a substitution.
  * **Anything on dead code.** An assertion that never executes is worse than one that never
    fails: it does not even appear in the coverage table. A function with **no callers at all** is
    a question about the design, and answering it is a prerequisite to contracting it. That is the
    only caller question worth asking here: how many, not what they pass.

## Converting existing code: the purge test

Everything above screens what to write **from scratch**. Converting a check that is already there
is a different move with its own failure mode, and it is the move you make constantly while
sweeping a codebase. One question screens it, and it is a fourth question rather than a fourth
reason to decline:

> Under `:purge`, would this change what the program **does**, or only what it **notices**?

Only what it notices → a contract. What it does → ordinary code, unconditional in every build.
`@pre`, `@post`, `@invariant` and `check/1` are all purgeable; a refusal the program must always
perform is not one of them.

```elixir
defp provider!(socket, provider) do
  atom = String.to_existing_atom(provider)
  true = Enum.any?(socket.assigns.connections, &(&1.provider == atom))
  atom
end
```

Every signal of shape says precondition: a caller obligation, violated only by a bad argument,
already raising, with a diagnostic that names neither the value nor the rule. Convert it and a
purged build accepts a **forged request** — the provider came from a form.

**The tell is not how the check is written, it is what happens if it is not there.** A `true = …`
match has no `case`, no `{:error, _}`, nothing shaped like control flow, which is exactly why a
sweep reads it as a contract written before Bond existed. Provenance settles it: data from outside
your system has no caller of yours to blame, so refusing it is behaviour, not diagnosis.

This is the inverse of *never rescue a Bond error to decide what your program does*, and the
direction that bites during an audit — **don't convert what the program does into something it
merely notices.**

When a load-bearing check cannot become a `@pre`, look for a `@post` beside it that purging cannot
weaken. Keep the refusal as ordinary code with a diagnostic naming the rule, then assert what the
function *returns* where the body validates what it *looked up* — the same value today, not
necessarily tomorrow, so a cross-check rather than a mirror.

> **Non-Redundancy assumes the two checks are the same check.** Before deleting either side of an
> apparent duplicate, remove it and ask what stops being true — in *every build you ship*.
> "Redundant" is a conclusion, not an observation: two checks that read alike may be an accident,
> a deliberate second line of defence, or a purgeable thing standing in front of one that is not.
> Only the first is redundancy in Meyer's sense.

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

**A map that travels between modules is a struct waiting to happen.** A bare map has nowhere to
put a law: no invariant can attach to it, so whatever is true of it is re-asserted at each use, or
more often nowhere. Lifting it gives the law one home that holds for every instance however
constructed, including ones built in fixtures.

```elixir
# Was a map of comparison scores passed between four modules.
defmodule Signals do
  use Bond
  defstruct title: nil, artists: nil, album: nil, duration: nil

  @invariant similarities_are_proportions:
               forall(s <- [subject.title, subject.artists, subject.album, subject.duration],
                 is_nil(s) or (is_float(s) and s >= 0.0 and s <= 1.0))
end
```

Two conditions make the lift pay, and they are the same condition twice:

  * **Move the operations in with it.** An `@invariant` is checked around the **public functions
    of its own module**, so a struct module with no operations is a struct whose invariant fires
    nowhere. If the functions that build and read the map are scattered as private helpers across
    the modules that use it, gathering them is most of the win — it removes the duplication *and*
    makes the invariant reachable. Before lifting, ask where the invariant would fire; if the
    answer is "at functions this module does not have", write those functions or don't lift.
  * **Give `defstruct` defaults that satisfy the invariant.** `%Signals{}` is valid syntax for
    anyone. With `nil` defaults under a stricter law, the first invariant to touch a bare struct
    raises `Bond.AssertionEvaluationError` instead of reporting a violation. Choose defaults that
    are the "nothing to say" value *and* legal — that is Meyer's base-case rule, and it is usually
    a better default than `nil` regardless.

The payoff compounds: once the map is a struct with a module, every function in that module is a
candidate for a `@pre`/`@post` of its own, and they are usually the pure, law-bearing functions
where contracts are worth the most.

## Where the rationale goes

You will often know *why* an assertion is worth having — the bug it catches, the reasoning behind
a bound. That belongs in the function's `@doc`, because Bond appends the generated contract
sections to it: prose there renders directly above the assertion it justifies, in the docs the
callers read. The same words in a `#` comment above the assertion reach nobody but whoever opens
the file.

A comment beside an assertion earns its place only when it records what the assertion **cannot
say about itself** and a caller does not need — a bound that came from a measurement, a
deliberate suppression, a formulation that looks like a mistake and is not. One or two lines.
Anything longer competes with the contract block it sits in, which exists to be read at a glance
as a specification.

**Write comments for people.** Not because agents don't read them, but because a source comment
is the wrong channel for agent-directed content: every reader pays for it, it is duplicated at
each site, and a comment paraphrasing these rules goes stale against them. Durable project
knowledge belongs where it loads regardless of which file is open — `AGENTS.md`, the files it
references, or project memory. Bond mechanics belong in the usage rules.

## Checklist for a new contract

1. **State what the function or type promises**, in terms a caller can rely on. If you cannot say
   it, you do not understand the thing well enough to contract it yet.
2. **Meaning or mechanism?** Mechanism goes in the body. "It resembles the body" is not the test.
3. **Is it *only* a type check?** Then `@spec` — unless the value arrives at runtime from outside
   the compiler's view, or violating it crashes confusingly elsewhere.
4. **Is it total?** Lead with a type check; gate partial predicates with `~>`.
5. **Is it available to the caller?** A `@pre` naming a `defp` (or a `@doc false` function) is one
   the client cannot discharge — so publish the predicate, rather than dropping the obligation.
6. **Justifiable from the specification alone**, or only from how you happened to implement it?
   And if you are *converting* an existing check: under `:purge`, would removing it change what
   the program **does** or only what it **notices**?
7. **Can it fail?** Write a `Bond.Test` assertion targeting its `label:`. Where no input can
   falsify it, mutate the implementation and confirm it fires.
8. **Does the reasoning belong in the `@doc`?** If you are about to write a comment explaining
   the assertion, that is where it goes — published, next to the contract, for the caller.
9. **Read the coverage table.** `⚠ never failed` is a question with four answers.
10. **When you add a precondition, audit its call sites.**
