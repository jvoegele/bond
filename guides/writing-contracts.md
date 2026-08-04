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
> guide covers the locking pattern that recovers correctness there.
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

> #### `forall` and `exists` {: .info}
>
> `forall` and `exists`, mentioned just above and used in the examples below,
> are Bond's two quantifiers. `forall(x <- enum, predicate)` asserts the
> predicate holds for every element; `exists(x <- enum, predicate)` asserts it
> holds for at least one.
>
> They earn their place by what they say on failure. A hand-written
> `Enum.all?(urls, &String.starts_with?(&1, "https"))` reports only `false`;
> `forall` reports the **counterexample** — which element failed, and its index:
>
> ```
> |   counterexample: element at index 2 ("http://x") does not satisfy `String.starts_with?(u, "https")`
> ```
>
> See `Bond.Predicates` for both, and the
> [Quantified assertions](getting-started.md#quantified-assertions)
> section of the Getting Started guide for a walkthrough.

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
