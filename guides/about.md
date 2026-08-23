# About

Bond is a Design by Contract library for Elixir. It lets you attach
executable specifications to functions:

- **`@pre`** describes what a function expects from its caller.
- **`@post`** describes what it guarantees in return.
- **`@invariant`** describes properties of a struct that every public
  function in its defining module preserves.
- **`check/1`** describes sanity assertions inside a function body.

At runtime, Bond verifies these predicates and raises with diagnostic
context — label, expression source, captured binding, and source
location — on the first violation.

## When to reach for Bond

**When typespecs aren't enough.** Typespecs declare types; contracts
declare *relationships*: "amount is positive and not larger than
balance", "result equals balance minus amount", "every operation
preserves `length(items) <= capacity`". Dialyzer can't reason about
those.

**To publish a specification, not just check one.** A contract states what a
function promises, and Bond renders those promises into your ExDoc output as
`#### Preconditions` and `#### Postconditions` — Eiffel's *short form*, the
interface with the implementation stripped away. Most of a contract's value is
delivered before anything runs, to whoever reads the docs.

**To catch bugs sooner than tests would.** Tests cover the scenarios
you wrote. Contracts run on every call. Long-running dev or staging
environments routinely surface contract violations on paths the test
suite never exercised. This is what a specification does when an
implementation disagrees with it — a consequence worth having, rather
than the reason to write one.

**Without paying for it in production.** Per-kind configuration
(`true | false | :purge`) lets you decide, per environment and per module,
what a build actually checks — everything, preconditions only, or nothing.
`:purge` removes the override at compile time, so a production BEAM can
contain no contract evaluation code at all.

**Alongside what you already have.** Contracts compose with StreamData
(your contracts are the PBT oracle), telemetry
(`[:bond, :assertion, :failure]` for every violation), and Norm (data
shape on the boundary, contracts inside).

## Background

Design by Contract was developed by Bertrand Meyer for the Eiffel
language in the mid-1980s, building on earlier formal-specification
work by Tony Hoare and others. For prior art in the Elixir ecosystem —
`elixir-contracts`, `ExContract`, `Oath` — and how Bond came to exist
as a distinct library, see the [History](history.md) guide.

For a hands-on walkthrough, see [Getting Started](getting-started.md).
