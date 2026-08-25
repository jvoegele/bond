# Contract shapes that pay off

A catalogue of the assertion shapes that repeatedly turn out to be worth writing, each with a
worked example and the class of bug it catches. Drawn from contracting a real application rather
than from the reference manual — every one of these was mutation-verified, meaning the
implementation was deliberately broken and the contract confirmed to fire.

Read this when you know a function needs a contract and are deciding *what* to assert.

---

## 1. One rule written twice, cross-checked

**The strongest shape.** Wherever the same rule exists in two places, nothing keeps them in step,
and drift is silent in both directions.

```elixir
@post query_agrees_with_predicate:
        forall(c <- result, Connection.needs_refresh?(c, DateTime.utc_now(), skew_seconds))
def connections_due_for_refresh(skew_seconds, opts)
```

That Ecto query and `needs_refresh?/3` are the same rule written twice — once in SQL, once in
Elixir. Too wide and the scheduler burns provider quota refreshing tokens that were fine; too
narrow and connections pass their expiry and die. Mutation-verified in both directions.

**Look for this wherever a rule exists twice:** a query and a predicate, a database constraint and
a changeset validation, a serializer and its parser, a cache key and the function that builds it.

### The process-state variant

```elixir
@state_invariant one_monitor_per_in_flight_key:
                   map_size(state.monitors) == map_size(state.in_flight),
                 monitors_point_back_at_their_keys: monitors_agree?(state)
```

A key's monitor reference lives both on its `in_flight` entry and as a key of `monitors`, so a
`:DOWN` can find the key it belongs to. A `release/3` that forgot to delete from `monitors` leaks
a reference per completed fetch forever; a stale entry there makes a later, unrelated `:DOWN`
release a key that is legitimately in flight.

---

## 2. Conservation — nothing invented, nothing lost

```elixir
@post no_tracks_invented: forall(track <- result, track.provider_id in item_ids(document))
@post never_more_than_requested: length(result) <= length(item_ids(document))
def tracks_from_items_page(document)
```

Catches a mapper reading from the wrong collection — mutation-verified by swapping `data` for
`included`. The general form is `matched + unmatched + skipped == total`.

### When duplicates are legal: compare multisets, not uniqueness

First written as a count plus a uniqueness check:

```elixir
# ❌ fires on correct code the moment the input genuinely repeats an item
@post every_track_accounted_for: Report.total(result) == length(pairs)
@post no_track_reported_twice: length(Enum.uniq(source_ids(result))) == length(pairs)
```

Uniqueness was never the law — it was a proxy for "nothing was duplicated *by the
implementation*", and the two come apart as soon as the input has duplicates of its own.

```elixir
# ✅ sound and strictly stronger — rejects a drop, a duplication AND a substitution
@post every_track_accounted_for_exactly_once:
        Enum.sort(source_ids(result)) == Enum.sort(source_ids(pairs))
```

It **replaced both** assertions rather than joining them. When tempted to assert a collection has
no duplicates, ask whether duplicates are illegal *in the domain* or merely unexpected in the
examples to hand.

---

## 3. Two accumulations of one truth, cross-checked before the write

```elixir
@pre report_agrees_with_counters: TransferItem.tally(items) == Transfer.tally(counted)
def record_run(transfer, items, counted)
```

The caller folds over the same resolutions **twice** — once accumulating integers, once building a
report row per track — and nothing held the two in step. A miscount in either fold produces "8/10
matched" above a report with nine matched rows. Neither number is obviously wrong and nothing
raises.

Three things make this worth copying:

  * **The pair of `tally/1` functions exists only so the comparison can be written.** Making two
    representations produce the same shape is often the whole work of stating the law.
  * **A precondition, not a postcondition** — the caller has the bug, and naming it *before* the
    write matters when a half-written report looks complete.
  * It is strictly stronger and cheaper than the database query it replaced, which counted rows
    and was satisfied by ten rows against ten tracks even when the counters disagreed.

---

## 4. Relationships that still "work" when broken

```elixir
@post whenever({:ok, authorization} <- result,
        challenge_is_hashed:
          challenge_in(authorization.url) == Base.url_encode64(:crypto.hash(:sha256, ...)),
        verifier_never_sent:
          challenge_in(authorization.url) != authorization.code_verifier)
def authorization_url(opts)
```

Catches sending the PKCE verifier where the challenge belongs. The flow still completes, the
exchange still succeeds, every test still passes — and PKCE's entire protection is gone.

This is the class where contracts are most clearly worth more than tests: **the system does not
appear to be broken.**

---

## 5. Units and magnitudes that are not type errors

```elixir
@pre skew_under_a_day: skew_seconds <= 86_400
```

Catches milliseconds passed where seconds are wanted (`300_000` for `300`). Nothing fails — every
token merely looks due for refresh on every call, and the application hammers the provider until
the rate limiter notices.

Bonus: `probe_contract/2` reads literal comparisons out of a `@pre` and aims generators at them,
so adding a bound gets boundary testing for free.

---

## 6. Values that are silently poisonous downstream

```elixir
@post non_negative: is_integer(result) ~> (result >= 0)
def parse_iso8601_duration(value)
```

ISO 8601 admits negative components, so `"PT-5S"` parses to `-5`. A negative duration is not a
shorter track — it is a value that scores as a *near miss* against real durations in a matching
engine. **The property test passed over this bug** because it only asserted `is_integer(result)`.

---

## 7. Idempotence and other laws about the function itself

A postcondition may **call the function it belongs to** — Bond suppresses contract checking while
evaluating an assertion, so the nested call terminates:

```elixir
@post idempotent: text(result) == result
```

Put a self-invoking assertion **last**, so cheaper ones fail first and name the problem more
precisely.

The real distinction is not "how many runs it takes to see" but **what the law relates**:

  * Two calls on the *same* value — idempotence, `f(f(x)) == f(x)` — is a claim about one result
    and belongs in a postcondition, where it holds over every input the application ever sees.
  * Two calls on *different* values — "these two spellings agree", "order does not matter" — has no
    single result to hang on, and stays a property test.

Check independence rather than assuming it. One function already asserted its output was
lowercase, alphanumeric-with-single-spaces, and trimmed — which sounds like it forces a fixed
point and does not. Leading-article stripping, a standard music-library normalization, separates
them: "The The Beatles" → "the beatles" → "beatles", satisfying all three at every step. (The band
The The is a real counterexample, not a contrived one.)

---

## 8. Boundary preconditions that protect a shared resource

```elixir
@pre normalized_barcode: barcode == Barcode.normalize(barcode)
def album_id(barcode, opts, fun)
```

An unnormalized barcode is not a *wrong answer*. It is a **different cache key for the same
release** — so the caller silently gets a private copy of every lookup, doubles the provider calls
the cache was meant to save, and writes a second row for a release that already has one. Nothing
raises and nothing is incorrect; the cache simply stops working, in a way that shows up as a bill.

This is why preconditions stay enabled in production: it names the *caller's* bug, and the caller
is the one who can fix it.

It also caught something immediately — not in the application, but in the tests, which had been
using readable labels like `"doomed"` as barcodes. **A fixture that cannot occur in production
tests nothing that matters.**

---

## Shapes to avoid

### A postcondition over a shared table

```elixir
# ❌ any concurrent write by a DIFFERENT user interleaves; accuses correct code
@post removed_exactly_one_row: connection_count() == old(connection_count()) - 1
```

The blast-radius law it was reaching for — a rewrite to `delete_all` with a filter missing the
`user_id` clause — is real and worth catching. It belongs in a **test**, where the sandbox makes
the state genuinely exclusive. What survives in the contract is the race-free half:

```elixir
@post removed_what_was_asked_for: removed.user_id == user_id and removed.provider == provider
```

Verified: the test catches the `delete_all` rewrite on its own, so moving the law lost no coverage.

### An assertion about a stream's contents

Consumes it — turning a lazy read into hundreds of HTTP requests, inside an assertion, on every
call. Contract the *eager* thing next to it instead.

### An invariant that cannot fire

An `@invariant` is checked only around **its own module's** public functions. Two failure modes,
and both are usually a smell about the code rather than the contract:

  * **A struct module with no operations.** One core domain struct had exactly one public function,
    which neither took nor returned the struct — so an invariant would have fired nowhere. The
    better question was why a struct that central had no operations, and the answer was that they
    were scattered as duplicated private helpers across three other modules. Gathering them removed
    the duplication and made the invariant reachable.
  * **A law reachable only from an assertion.** Lifting a map to a struct so its ledger law becomes
    an invariant is tempting — but if the only caller is inside another function's `@pre`, the
    Assertion Evaluation rule suppresses it and the invariant is checked **exactly nowhere**.

**Before lifting a map to a struct for an invariant's sake, ask where the invariant would fire.**
If the answer is "at functions this module does not have" or "inside somebody else's assertion",
the lift buys a name and nothing more.
