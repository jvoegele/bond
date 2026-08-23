# Writing Contracts

The complete reference for the contract annotations and the assertion language
they are written in. If you are new to Bond, the
[Getting Started](getting-started.md) guide covers the same ground one example at
a time; come here for the details.

## Usage

`use Bond` in any module to enable the `@pre`, `@post`, and `@invariant`
annotations plus the `check/1` macro. Contracts may use any Elixir
expression that returns a boolean (or a truthy value).

```elixir
defmodule Math do
  use Bond

  @pre numeric_x: is_number(x), non_negative_x: x >= 0
  @post float_result: is_float(result),
        non_negative_result: result >= 0.0,
        "sqrt of 0 is 0": (x == 0) ~> (result === 0.0),
        "sqrt of 1 is 1": (x == 1) ~> (result === 1.0),
        "x > 1 implies result smaller than x": (x > 1) ~> (result < x)
  def sqrt(x), do: :math.sqrt(x)
end
```

This one is chosen to show the syntax rather than to argue the case, and the two
preconditions are the half you should *not* copy: they restate what a
`when is_number(x) and x >= 0` guard enforces, so with the guard present neither
can ever fail. Write one or the other, not both — see
[Should I remove guards when I add contracts?](faq.md#should-i-remove-guards-and-pattern-matches-when-i-add-contracts).
The three implication clauses are the interesting half — `~>` reads "implies", so
`(x > 1) ~> (result < x)` asserts nothing at all unless `x > 1`, and asserts
`result < x` when it does. Each relates the input to the result, which no guard
can express.

`@pre` and `@post` accept one or more labelled assertions. Preconditions
have access to the function's parameters; postconditions also have access
to the `result` variable (bound to the function's return value) and
`old(...)` expressions that snapshot a value before the function runs (see
[`old` expressions](#old-expressions) below).

> #### `use Bond` {: .info}
>
> `use Bond` overrides `Kernel.@/1` so that `@pre`, `@post`, `@invariant`,
> and `@doc` annotations can be intercepted and recorded, and installs
> `@on_definition`, `@before_compile`, and `@after_compile` compiler hooks
> that wrap functions with contracts via `defoverridable` at the end of
> module compilation. Your `def`s and `defp`s are otherwise left alone.
>
> `use Bond` also imports the `Bond` module so the `check/1` macro is
> available, and imports `Bond.Predicates` so the predicate functions and
> operators defined there (such as `~>` and `|||`) can be used in
> assertions. `Bond.Predicates` can be explicitly imported elsewhere if
> you want the operators outside of contract expressions.
>
> To coexist with another library that overrides `Kernel.@/1` (such as
> Norm's `@contract`), pass `use Bond, at_annotations: false`: Bond then leaves
> `@` alone and you write contracts as the qualified calls `Bond.pre/1`,
> `Bond.post/1`, and `Bond.invariant/1`. See the FAQ for details.

### Multi-clause functions must agree on parameter names

A contract names its arguments, so every clause of a contracted function has to
agree on what each position is *called*. Where they disagree at a position a
contract references, Bond stops with a compile error:

```text
** (CompileError) Bond requires consistent top-level parameter names across all
   clauses of needs_refresh?/3 when contracts are attached.
   Position 1 disagrees: :_skew, :skew_seconds.
```

Two details make this less restrictive than it first reads:

  * **A leading underscore does not count.** `_now` in one clause and `now` in
    another agree — Bond strips one leading underscore before comparing. Mark an
    unused parameter `_skew_seconds`, not `_skew`, and the clause keeps both the
    warning suppression and the agreed name.
  * **Only positions a contract actually references matter.** Clauses may
    disagree freely at a position no assertion mentions; Bond gives it a
    generated name and moves on.

You will not find this by reading — it is discoverable by hitting it — which is
why the diagnostic prints each clause's names side by side and says which
position disagrees.

## Assertion syntax

An assertion is a boolean (or truthy) Elixir expression, optionally paired
with a label. Labels are supplied via the **keyword list** form and are
atoms — quote the key for spaces or punctuation. They appear in error
messages and generated documentation.

The keyword list is the recommended (and only) labelling form, even for a
single assertion:

```elixir
@pre positive_x: x > 0
@post non_decreasing: result >= x
@pre numeric_x: is_number(x), non_negative_x: x >= 0
@pre "x must be positive": x > 0
```

For a bare assertion where a label adds no information, the **bare form**
is also fine:

```elixir
@pre is_number(x)
@post is_float(result)
```

The assertion expression can be any call or operator returning a
truthy/falsy value — including remote function calls from the standard
library or your own modules:

```elixir
@pre String.starts_with?(path, "/api/")
@pre Map.has_key?(opts, :user_id)
@post Enum.all?(result, &is_integer/1)
```

A precondition on a **public** function should call only what its callers can
call: a caller cannot evaluate an obligation stated in terms it has no access
to. Bond warns when a public function's precondition calls a `defp` — Meyer's
Precondition Availability rule. See
[How do I reuse a predicate across several functions?](faq.md#how-do-i-reuse-a-predicate-across-several-functions).
Postconditions are unaffected: they are the *function's* promise, so they may
freely reference private helpers.

Bare literals (`@pre 42`), bare variables (`@pre x`), and other non-call
expressions aren't valid assertion forms — Bond raises a `CompileError`
with the source location and a suggested form when it sees one.

The same two forms work for `@invariant` declarations and inside function
bodies via the `check/1` macro:

```elixir
@invariant subject.capacity >= 0
@invariant non_negative_capacity: subject.capacity >= 0,
           size_within_capacity: length(subject.items) <= subject.capacity

check is_number(x)
check x_is_number: is_number(x)
```

Bond also provides the `Bond.Predicates` module with operators that are
often useful in assertions — notably `~>` (logical implication) and `<~`
(pattern match). `Bond.Predicates` is automatically imported into
assertion expressions, so you can use these operators directly:

```elixir
@post (x == 0) ~> (result == 0.0)
@post {:ok, _} <~ result
```

> #### Operator precedence trap {: .warning}
>
> `~>` and `<~` share precedence and left-associate. Nesting them
> (`A ~> pattern <~ B`) parses as `(A ~> pattern) <~ B` and fails to
> compile. Parenthesize the inner operator:
> `(x > 0) ~> ({:ok, _} <~ result)`. See `Bond.Predicates` for details.

See `Bond.Predicates` for the full list of predicates and operators.

## Quantified assertions

To assert something about *every* element of a collection — or that *some*
element exists — use the `forall` and `exists` macros. Both take one
comprehension-style generator and one predicate:

```elixir
defmodule Stats do
  use Bond

  @pre all_positive: forall(x <- samples, x > 0)
  def geometric_mean(samples) do
    :math.pow(Enum.product(samples), 1 / length(samples))
  end
end

defmodule Roster do
  use Bond

  @pre has_admin: exists(u <- users, u.role == :admin)
  def authorize(users), do: Enum.map(users, &grant/1)
end
```

You could write both with `Enum.all?/2` and `Enum.any?/2`. What you would lose is
the diagnosis: when one of those fails, Bond can only report that the whole
expression was false. A quantifier reports **which element** broke the contract,
and where it was:

```
** (Bond.PreconditionError) precondition failed for call to Stats.geometric_mean/1
|   label: :all_positive
|   assertion: forall(x <- samples, x > 0)
|   counterexample: element at index 3 (-2) does not satisfy `x > 0`
|   binding: [samples: [5, 2, 8, -2]]
```

`exists` instead reports that no element satisfied the predicate, and how many it
looked at:

```
** (Bond.PreconditionError) precondition failed for call to Roster.authorize/1
|   label: :has_admin
|   assertion: exists(u <- users, u.role == :admin)
|   counterexample: no element of `users` satisfies `u.role == :admin` (3 elements)
|   binding: [users: [%{role: :user}, %{role: :guest}, %{role: :user}]]
```

Both forms:

- **short-circuit** — `forall` stops at the first violation, `exists` at the
  first witness;
- return ordinary booleans, so they **compose** with `and`, `or`, `not`, and `~>`;
- work in `@pre`, `@post` (including quantifying over `result`), `@invariant`,
  the `Bond.Server` `@state_invariant` / `@transition_invariant`, and `check/1`.

Quantifying over `result` reads naturally — asserting a function returns a sorted
list, for example:

```elixir
@post sorted: forall(i <- 0..(length(result) - 2)//1,
                     Enum.at(result, i) <= Enum.at(result, i + 1))
def sort(list), do: Enum.sort(list)
```

### Not a `for` comprehension (or a property generator)

The `pattern <- enumerable` syntax is borrowed from `for` comprehensions — and
looks like StreamData's `check all` / `gen all` — but the resemblance is only
skin-deep. Two differences worth internalising:

- The right-hand side of `<-` is a **plain `Enumerable`** (a list, range, map,
  stream…), not a StreamData generator. The closest analogues are `Enum.all?/2`
  and `Enum.any?/2`, not `for` or property testing.
- The trailing expression is the **predicate being asserted**, *not a filter*. In
  `check all x <- list, x > 0 do … end`, the `x > 0` clause *discards*
  non-matching values; in `forall(x <- list, x > 0)` it is the thing that must
  hold for every element. There is no `do` block.

So read `forall(x <- items, x > 0)` as the logical statement "for all `x` in
`items`, `x > 0`" — not "for the `x` in `items` where `x > 0`".

The generator *pattern* follows the same rule: it binds, and a structural pattern
also asserts shape, so a non-matching element **fails** the contract rather than
being skipped. See [Quantifier generators bind and assert shape](writing-sound-assertions.md#quantifier-generators-bind-and-assert-shape-they-do-not-filter)
for that distinction and the `~>` idiom that recovers comprehension-style
filtering.

### Limitations

- Each quantifier takes **one generator and one predicate**; there is no
  multi-generator or filter syntax as in a `for` comprehension. Nest a quantifier
  inside another for a Cartesian assertion. (A `for`-style multi-generator call
  raises a clear compile-time error pointing you at nesting.)
- When several quantifiers appear in one assertion — including **nested** ones —
  the element-level `counterexample:` line reflects the outermost
  (last-evaluated) quantifier to fail. For a single, bare quantifier it is exact.
  The plain truthy/falsy verdict is always correct regardless. See
  [Why does my nested `forall` report the row instead of the failing inner element?](faq.md#why-does-my-nested-forall-report-the-row-instead-of-the-failing-inner-element)

### Large collections, streams, and side effects

A quantifier **enumerates the collection** — once, lazily, stopping at the first
violation (`forall`) or first witness (`exists`). Keep three things in mind:

- **Cost is `O(n)`.** Quantifying over a large collection on a hot path adds a
  full (short-circuited) traversal to every call, just like `Enum.all?/2` would.
  This is what Bond's runtime gate is for — disable the kind in production
  (`config :bond, postconditions: false`, or `Bond.Config` at runtime; see
  [Choosing what runs in production](configuration.md#choosing-what-runs-in-production))
  so the traversal never runs there.

- **Assertions must be side-effect-free — and enumerating a lazy stream is a side
  effect.** A `@post` that quantifies over a stream `result` (or a `@pre` over a
  stream argument) will *enumerate that stream* to check the predicate. For a
  pure, re-enumerable stream that merely **doubles the work** — the stream runs
  once for the contract and again for the caller. But for a stream backed by a
  **one-shot or effectful source** — `IO.stream/2` over stdin, an
  `Ecto.Repo.stream` cursor, a socket via `Stream.resource/3` — the contract's
  enumeration consumes or re-fires the resource, corrupting what the caller
  receives. **Don't quantify over an effectful stream.** If the producer is
  finite and pure and you really want to assert over it, materialise it
  explicitly — `forall(x <- Enum.to_list(result), …)` — so the cost and the
  single enumeration are visible at the call site.

- **Never quantify over an infinite stream.** `forall` returns only when an
  element *fails*, and `exists` only when one *succeeds* — so an all-passing
  `forall` (or a no-match `exists`) over `Stream.cycle/1`, `Stream.iterate/2`,
  etc. never terminates. Bond can't detect this (a finite and an infinite stream
  have the same type); it's on you to quantify only over bounded collections.

## `old` expressions

`old` expressions in postconditions snapshot a value before the function
body runs, so the postcondition can compare the after-state to the
before-state. Useful when a function mutates state that the postcondition
needs to talk about as both "before" and "after."

```elixir
defmodule TurnCounter do
  use Bond

  # Per-process turn counter stored in the process dictionary. Single-
  # process state by design — owned by exactly the process running the
  # function, so `old` captures a snapshot nothing else can interleave
  # against.

  def current_turn, do: Process.get(:turn, 0)

  @post incremented: current_turn() == old(current_turn()) + 1
  def take_turn do
    Process.put(:turn, current_turn() + 1)
    :ok
  end
end
```

Bond resolves every `old(...)` expression at the start of function
execution and threads the captured value into the postcondition. `old`
is only available inside `@post`.

The process dictionary fits the demo cleanly because it's stateful
(otherwise there'd be no "old" to talk about — for an immutable
parameter `x`, `old(x)` and `x` are the same value) but local to a
single process (so the snapshot and the post-check observe the same
world). The same shape works for any single-process-owned state: an
ETS table created with `:protected` or `:private` access, a `Process`
dictionary entry like above, a value held in the current process's
closure.

> #### Concurrent state needs a different pattern {: .warning}
>
> If `old(expr)` reads state that another process can write to between
> the snapshot and the postcondition evaluation — an `Agent`, a
> `GenServer.call/3`, a shared ETS table — another process can
> interleave and the comparison becomes meaningless. The
> [Contracts in a Concurrent World](contracts-and-concurrency.md)
> guide works through what you can honestly assert in that case, and the
> refactoring that lets you assert the strong version somewhere else.
> For struct-based state machines, `@invariant` is usually a better
> fit than `old` — it constrains every operation's input and output
> struct rather than a single delta.

## Inline `check/1` assertions

Bond's `check/1` macro places assertions at arbitrary points inside a
function body — useful for sanity checks during development. It honours
the `:bond, :checks` config (see
[Configuring Contracts](configuration.md)) and is safe to disable in
production builds.

```elixir
def total(items) do
  raw = Enum.sum(items)

  check raw >= 0
  check total_is_integer: is_integer(raw)

  raw
end
```

On success `check` returns the assertion's value (or list of values for
the keyword-list form). On failure it raises `Bond.CheckError`.

### Recording *why* a call is legitimate

`check`'s best use is narrower and more valuable than "a sanity assertion". Meyer calls
it the most useful application of the construct (§11.11): put a `check` immediately before
a call whose precondition you are convinced you have established, when the reason is not
obvious from the surrounding code.

```elixir
def summarise(readings) do
  cleaned = Enum.reject(readings, &is_nil/1)

  # Because `readings` had at least one non-nil entry — guaranteed by the @pre
  # on this function — rejecting nils cannot empty the list.
  check non_empty: cleaned != []

  Stats.mean(cleaned)          # @pre non_empty: samples != []
end
```

Without the `check`, a later reader sees an unguarded call to a function with a
precondition and cannot tell whether the absence of a guard was reasoning or oversight.
The `check` says it was reasoning, names the assumption, and fails loudly in dev if the
reasoning was wrong. Meyer's convention of writing the justification as a comment beside
it is worth copying: the assertion records *what* you assumed, the comment records *why*
you were entitled to.

> #### When to use `check` {: .warning}
>
> Don't use `check` for input validation, validating data from external
> systems, or anything else that protects the integrity of your code. If
> the check were removed (or compiled out via config), the system must
> still behave correctly. Use ordinary control flow for that.

## Destructuring bindings: `where` and `whenever`

The `<~` operator matches a pattern but its bindings don't escape — names
bound in the pattern can only be constrained by a `when` guard, and guards
are a closed sublanguage (no `exists`/`forall`, no function calls, no
comparisons against computed values). When you need Bond's **full** assertion
syntax on a value nested inside a result — a list inside a map inside a tuple,
say — reach for `where` or `whenever`.

Both wrap a destructuring binding and scope a set of ordinary (optionally
labelled) assertions to the names it binds:

```elixir
# `where` (=) asserts the shape: a non-match is a contract violation.
@post where({:noreply, %{keys: new_keys, timer: timer}} = result),
      timer_ref:  is_reference(timer),
      has_target: exists(k <- new_keys, k.key == "a")

# `whenever` (<-) is conditional: a non-match is vacuously satisfied.
@post whenever({:ok, %{urls: urls}} <- result),
      non_empty: urls != [],
      all_https: forall(u <- urls, String.starts_with?(u, "https"))
```

The keyword carries the semantics and the arrow reinforces it: **`where` uses
`=`** (the result *is* this shape — a mismatch fails, exactly like `=` raising
a `MatchError`), and **`whenever` uses `<-`** (the result *might* match — like
a `with`/`for` generator, a mismatch is skipped). A mismatched keyword/arrow
pair is a compile error.

Because `whenever` is vacuous on a non-match, **case analysis is one `whenever`
per shape** — no `or {:error, _}` boilerplate. Each line checks only its own
case:

```elixir
@post whenever({:ok, payload} <- result), valid: valid?(payload)
@post whenever({:error, reason} <- result), known: reason in [:timeout, :refused]
```

A nice side effect: each scoped assertion has its own label, so a violation
pinpoints exactly which shape and constraint failed, rather than reporting a
single lumped label for a `<~`-with-`when`-guard alternation. If you migrate an
existing guarded `<~` contract to per-shape `whenever` clauses this way, expect
the reported violation labels to become more specific — handy in practice, but
something to update if you have tests asserting on the old label.

The scoped assertions are ordinary assertions — bare or labelled, using any
predicate, operator, quantifier, or function call — and each is reported
individually on failure. The forms work in `@pre` (binding from arguments),
`@post` (and `result`), `@invariant` (from `subject`), and the `Bond.Server`
`@state_invariant` / `@transition_invariant` (from `state` /
`old_state`/`new_state`). They are also available in **inherited contracts** —
`Bond.Behaviour` callback contracts and `Bond.Protocol` function contracts —
where the binding source references the callback/function's argument names (and
`result`), exactly like a plain inherited `@pre`/`@post`.

Both forms are recognised at the **start** of a contract — they are not boolean
sub-expressions, so they can't appear inside `~>`, `or`, or a larger expression.
Bond raises a compile error naming the alternatives if you try. See
[How do I bind names inside `~>` or `or`?](faq.md#how-do-i-bind-names-inside-or-or)
for the three patterns that cover this, all of which keep per-assertion labels.

### The all-inside form (call contexts)

The prefix form above (`@post where(binding), assertion…`) relies on the `@`
syntax. The **call-style** entry points — `Bond.pre`/`Bond.post`/`Bond.invariant`
(used with `at_annotations: false`) and `check/1` — are ordinary fixed-arity
macros, so they take the *all-inside* form, where the assertions live inside the
`where(…)`/`whenever(…)` call:

```elixir
# at_annotations: false
Bond.post(where({:ok, items} = result, nonempty: items != []))

# inline check — bindings are scoped to the check (they don't leak), and a
# violation raises `Bond.CheckError`; a `whenever` non-match is a no-op
check whenever({:ok, payload} <- fetch(), valid: valid?(payload))
```

The all-inside form also works in the `@` annotations as an alias of the prefix
form (`@post where({:ok, x} = result, pos: x > 0)`).

> #### Known limitation {: .info}
>
> If a `where`/`whenever` pattern binds a name identical to a top-level
> function parameter (e.g. a parameter `keys` and a pattern `%{keys: keys}`),
> that parameter is shadowed inside the group and Elixir emits an "unused
> variable" warning. The contract is still correct; rename the parameter or
> the bound name to silence it.

## Documenting contracts

Contracts are part of a module's public interface, in the same way that
function signatures and typespecs are. Bond treats them that way: every
function with a contract gets a `#### Preconditions` and/or
`#### Postconditions` section appended to its `@doc`, formatted as the
original assertion source. The sections appear in `ex_doc` output and in
editors that show function docs on hover (VS Code, Vim's `K`, etc.).

Auto-generated contract sections appear whether or not you wrote a `@doc`
yourself — Bond synthesises one when needed.

This is Eiffel's *short form*: the view of a module with implementations stripped
away and only the specification left. It is what makes it reasonable to treat a
contract as the published interface rather than an internal test aid, and it means
most of a contract's value is delivered before anything runs — see
[What Should a Contract Say?](what-contracts-say.md#a-one-line-implementation-still-deserves-a-specification).

`@invariant`s are documented at the **module** level: a module that declares
invariants gets a `## Invariants` section appended to its `@moduledoc`, naming the
struct, explaining the `subject` binding, listing each invariant in the same
`label: expression` format, and noting when the invariants fire. As with
per-function docs, Bond synthesises a `@moduledoc` when you haven't written one,
and respects `@moduledoc false`.

> #### Conditional compilation and docs {: .info}
>
> When a function has **all** of its contracts `:purge`d (see
> [Configuring Contracts](configuration.md)), the function runs
> with zero contract overhead and its auto-generated contract sections are
> suppressed; likewise, `:invariants` set to `:purge` suppresses the generated
> `## Invariants` section.
>
> This only affects docs *compiled in a purging environment*. `mix docs` runs in
> whichever `MIX_ENV` you invoke it in — `:dev` by default — where contracts are
> normally enabled, so a `:purge` confined to `config/prod.exs` does **not** strip
> your published HexDocs: you generate them in dev, not prod. The suppression only
> removes contract documentation from a *build* that itself purges — for example,
> browsing `h MyModule.fun/1` in a production release console. If you want it
> present even there, leave at least one of `:preconditions` / `:postconditions` /
> `:invariants` set to `true` or `false` (those emit the override; only `:purge`
> removes it).
