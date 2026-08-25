# What Should a Contract Say?

Bond gives you the syntax for writing assertions and no opinion about what to put in
them. This guide is about that question — not whether an assertion is *sound* (the
next guide covers that), but what it should be *saying* in the first place.

The short answer: a contract states what a function promises. Catching bugs is what
that does when an implementation disagrees with its promise, which is a consequence
worth having but not the purpose.

That distinction sounds academic and is not. It changes which contracts get written.

## The instruction is prescriptive; the assertion is descriptive

Meyer puts it directly. A stack's `full?` has an obvious implementation, and a
postcondition that appears to say the same thing:

```elixir
@post definition: result == (stack.count == stack.capacity)
def full?(%__MODULE__{} = stack), do: stack.count == stack.capacity
```

The natural reaction is that the postcondition is redundant — the body already says
it, with `=` in place of `==`. It is not:

> The instruction is prescriptive; the assertion is descriptive. The instruction
> describes the "how"; the assertion describes the "what". The instruction is part of
> the implementation; the assertion is an element of specification.
>
> — *Object-Oriented Software Construction*, 2nd edition, §11.7, p. 352

The body is a command: compute this. The assertion is a claim about the end state
that a caller can rely on without reading the body. They resemble each other here
only because the implementation is trivial, and Elixir's `==` looks like Eiffel's `=`.

Meyer answers the obvious objection — that a *plausible rewrite* could never violate
it — on its own terms. The body could just as well have been:

```elixir
def full?(%__MODULE__{} = stack) do
  if stack.count == stack.capacity, do: true, else: false
end
```

The postcondition is what says those two are the same function. And the resemblance
is an artefact of the example being one line. Meyer's own next case is a square root,
whose postcondition is `abs(Result ^ 2 - x) <= tolerance` — nothing about which looks
like an algorithm for computing square roots:

```elixir
@post within_tolerance: abs(result * result - x) <= 1.0e-9
def sqrt(x), do: # ... Newton-Raphson, or whatever you like
```

Same specification, wildly different implementation. That is the normal case; `full?`
is the degenerate one.

## The test is mechanism versus meaning

"Does the assertion restate the body?" is the wrong question, because for a
short function the answer is often yes and the contract is still worth having.
The question that holds up is **whether the assertion describes mechanism or
meaning**.

```elixir
# ❌ Mechanism. This is the implementation, spelled twice.
@post mapped: result == Enum.map(xs, &transform/1)
def process(xs), do: Enum.map(xs, &transform/1)

# ✅ Meaning. It happens to fit on one line, but it is a claim about the
#    result, not a recipe for producing it.
@post definition: result == (stack.count == stack.capacity)
def full?(%__MODULE__{} = stack), do: stack.count == stack.capacity
```

The first names the algorithm — `Enum.map` over `xs` applying `transform/1`. Change
the implementation to a `for` comprehension or a `Stream` and you must change the
assertion in the same edit, because the assertion *is* the implementation.

The second names a property. It survives any rewrite of `full?` that remains correct,
which is precisely what you want a specification to do.

A useful sharpening: if you cannot describe the assertion without describing how the
function works, it is mechanism.

## A one-line implementation still deserves a specification

The strongest argument against discarding `full?`'s postcondition is that Bond
publishes it.

Bond generates `#### Preconditions` and `#### Postconditions` sections into ExDoc from
your contracts — Eiffel's *short form*, the view of a class with implementations
stripped out and only the specification left. That is what makes it reasonable to
treat a contract as the published interface rather than an internal test aid.

A postcondition that mirrors a one-line body still tells every reader of the docs what
the function guarantees, without asking them to read the source. Most of its value is
delivered before anything runs.

So "delete it, it can never fail" trades a published specification for nothing. If the
assertion states meaning rather than mechanism, keep it.

## Well-behaved callers are not a reason to skip a contract

The same mistake has a second form, which looks at the *callers* rather than the body:

> Every caller of `withdraw/2` checks the balance first, and two of them have contracts
> of their own saying so. A `@pre` here could never fire.

It could never fire *today*. A precondition is not a claim about the call sites that
happen to exist when you write it — it is a standing obligation on every call site that
will ever exist:

```elixir
@pre sufficient_funds: amount <= account.balance
def withdraw(%Account{} = account, amount)
```

And call sites arrive: a new feature, a refactor that routes an old path somewhere new, a
second application once the module ships as a library. Nothing else in the codebase meets
that eleventh caller. The other ten callers' contracts constrain *them*; they say nothing
about `withdraw/2`, and they stop covering anything the moment somebody adds a caller
without reading them.

So the reasoning runs the other way round. Careful callers are why this row will read
`⚠ never failed` in the coverage table for a year — not a reason to leave it unwritten.
The day it does fire, it names the caller that got it wrong, at the call, instead of
letting a negative balance travel somewhere it will be much harder to explain.

The same holds for a supplier: a `@post` is not made redundant by an implementation that
currently satisfies it. Satisfying it is the normal state. The contract is what tells you
the day that changes.

## Three questions

When you are unsure what to write, these are usually enough:

**What must the caller guarantee for this call to make sense?** That is the `@pre`.
Not "what would crash the body" — what the *specification* requires. A precondition
you cannot justify from the function's stated purpose is usually the implementer's
convenience leaking into the interface.

**What does this function promise in return?** That is the `@post`. State it as a
property of `result` — and of the arguments, and of `old(...)` state where something
changed. If the honest answer is "whatever the body computes", there is nothing to
say and you should say nothing.

**What is always true of this value, between calls?** That is the `@invariant`. It
belongs to the type rather than to any one function, and Bond checks it around every
public function of the declaring module.

## Where soundness comes in

Everything above is about what a contract *means*. Whether it *works* — whether it can
actually fail on the input it is meant to reject, whether it is total, whether it says
what it appears to say — is a separate question, and a large one.

Falsifiability is how you check an assertion is good. Stating the specification is why
you write one. Both matter; they are not the same test, and applying the first as
though it were the second is how correct specifications get deleted.

[Writing Sound Assertions](writing-sound-assertions.md) is the next guide, and covers
the second question in full.

## See also

  * [Writing Sound Assertions](writing-sound-assertions.md) — making an assertion
    behave the way it reads.
  * [Writing Contracts](writing-contracts.md) — the syntax for all of the above.
  * [Invariants](invariants.md) — what belongs to a type rather than a call.
  * [Contract Inheritance](contract-inheritance.md) — one specification, many
    implementations, which is where the specification framing pays most.
