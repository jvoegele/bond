# Bond usage rules

Bond is Design by Contract for Elixir: `@pre`, `@post`, `@invariant` and `check/1` compiled into
your functions, checked at runtime, and rendered into your ExDoc.

**A contract is a specification, not a test.** It states what a function promises, in terms a
caller can rely on. Catching bugs is what that does when an implementation disagrees with its
promise — a consequence worth having, but not the purpose. That distinction decides which
contracts get written, so lead with it.

Sub-rules: `bond:testing` (proving contracts fire, property testing, coverage) and
`bond:inheritance` (behaviours, protocols, `defcontract`).

## The default is yes

**Aim for a contract on every non-trivial function.** Everything else in these rules constrains
*what* to write; almost none of it is a reason to write *nothing*. Read the "do not write" list
as a quality bar on the assertion you are about to write, not as a gate you have to argue your
way through first.

This needs saying because the failure mode is one-sided. A codebase with too few contracts looks
exactly like a codebase that did not need them — nothing is missing, nothing is red, and the
functions that quietly promise nothing are invisible. Under-contracting is the default outcome of
careful screening, and it is the one nobody notices.

Measured on a Phoenix application contracted with these rules: **67 of its 126 source files**
`use Bond`, carrying 136 postconditions, 28 preconditions and 13 struct invariants across 12
struct modules. Its author's judgement was that reaching that density took five passes, because
every earlier pass had stopped too early.

Two things follow from that ratio of nearly **five postconditions to every precondition**:

  * **Most functions have something to promise; far fewer have something to demand.** If you are
    looking for a `@pre` and not finding one, that is normal — ask what the function *returns*
    instead, which is where the interesting laws are.
  * **Start from the promise, not from the screening.** Ask "what does this guarantee?" first. If
    you can state it, write it. If you genuinely cannot, that is a finding about the function —
    usually that it does two things, or that its result has no describable shape — and it is worth
    a moment's thought rather than a shrug.

The bar does not move. A contract that restates mechanism, cannot be evaluated, or accuses correct
code is worse than nothing, and none of what follows is suspended by this section. What changes is
the presumption: **contract it unless one of the stated reasons applies**, rather than contract it
only where the case is overwhelming.

## Setup

```elixir
# mix.exs
{:bond, "~> 1.17"},
{:stream_data, "~> 1.0", only: [:dev, :test]}   # only if you want Bond.PropertyTest
```

```elixir
# .formatter.exs — add :bond, or the formatter rewrites the binding forms
import_deps: [:bond]
```

A plain labelled contract (`@pre positive: x > 0, small: x < 10`) is one keyword-list argument and
survives without this. The **multi-argument** forms — a `where`/`whenever` binding followed by
scoped assertions — do not. Verified on 1.16.0:

```elixir
# written, and what you get back without import_deps: [:bond]
@post where({:noreply, %{timer: t}} = result), timer_ref: is_reference(t)
@post(where({:noreply, %{timer: t}} = result),
  timer_ref: is_reference(t)
)
```

## Rule 0: the module must `use Bond`

Check this before diagnosing anything else. Bond works by overriding `Kernel.@/1`; without
`use Bond` the annotations fall through to plain module attributes and **none of the resulting
errors mentions Bond**:

| What you wrote | What you get without `use Bond` |
| --- | --- |
| A `@pre` referencing a parameter | `error: undefined variable "x"` |
| A `@post` referencing `result` | `error: undefined variable "result"` |
| A multi-label `@post` | `expected 0 or 1 argument for @post, got: 2` |
| An assertion referencing nothing | Compiles, **enforces nothing**, warns only `module attribute @pre was set but never used` |

The last one is the dangerous one. If a contract seems to be doing nothing, check for
`use Bond` first, not last.

The same applies to a macro that *emits* `@pre`: the `@` inside its `quote` resolves in the
defining module's context, so **that** module needs `use Bond` too.

## Writing a contract

```elixir
defmodule Account do
  use Bond

  defstruct owner: nil, balance: 0

  @invariant non_negative: subject.balance >= 0

  @pre positive_amount: amount > 0,
       sufficient_funds: amount <= account.balance
  @post debited: result.balance == account.balance - amount
  def withdraw(%Account{} = account, amount) do
    %{account | balance: account.balance - amount}
  end
end
```

  * **Always use the labelled keyword form.** The label appears in the failure message and lets
    a test target that specific clause. `@pre positive: x > 0`, not `@pre x > 0`.
  * **One claim per assertion.** Splitting `a and b and c` into three labelled assertions turns
    one ambiguous failure into a precise one and makes each individually testable.
  * `@post` sees the parameters plus `result`. `old(expr)` (in `@post` only) snapshots a value
    at entry.
  * `@invariant` uses `subject` for the struct instance, and is checked around every **public**
    function of the struct's **own** module. `defp` is exempt by design — that is how you say a
    helper may legitimately see a transiently-invalid struct.
  * `check/1` asserts mid-body. It is for recording *why* a call is legitimate, not for
    validation — it can be compiled out.
  * Contracts attach to a **function**, not a clause: put them before the first clause. A `@pre`
    between clauses is a compile error.

## The traps

These are the places where the obvious guess is wrong. Most of them are silent.

### `forall`/`exists` bind and assert shape — they do not filter

```elixir
@pre all_positive: forall(x <- samples, x > 0)
@pre has_admin:    exists(u <- users, u.role == :admin)
```

Despite the comprehension-looking syntax:

  * The trailing expression is **the predicate being asserted**, not a filter. There is no `do`
    block.
  * The right side of `<-` is a **plain `Enumerable`**, not a StreamData generator.
  * A **structural** generator pattern *asserts shape*: `forall(%{retry: r} <- entries, r >= 0)`
    **fails** on an entry with no `:retry` key — it is not silently skipped, the way a `for`
    comprehension would skip it.

To get comprehension-style filtering, gate the predicate with `~>` so non-matching elements pass
vacuously — **parenthesising the consequent**, see below:

```elixir
forall(entry <- entries, match?(%{retry: _}, entry) ~> (entry.retry >= 0))
```

One generator and one predicate each; nest for a Cartesian assertion. Under nesting, only the
outermost quantifier's `counterexample:` line is reported (the verdict is always correct).

**Never quantify over an infinite stream** (`forall` only returns when an element fails, so it
never terminates), and **never over an effectful one** — enumerating a lazy stream is a side
effect, so a `@post` over an `IO.stream/2`, an `Ecto.Repo.stream` cursor or a socket consumes
what the caller was going to get. Materialise it first if you really mean to assert over it.

### `|||` is exclusive-or, not "or"

```elixir
Enum.empty?(remaining) or is_reference(timer)     # ✅ disjunction
Enum.empty?(remaining) ||| is_reference(timer)    # ❌ XOR — also fails when BOTH are true
```

Use `or`. Reach for `xor/2` (or `|||`) only when you genuinely mean "exactly one". If you import
`Bond.Predicates` into a function body, scope it: `import Bond.Predicates, only: [~>: 2]`.

### `~>` short-circuits; `implies?/2` does not

`~>` is a macro; `implies?/2` is a function, so both its arguments are evaluated before the call.

```elixir
false ~> raise("boom")            # true — right side never runs
implies?(false, raise("boom"))    # ** (RuntimeError) boom
```

Use `~>` whenever the consequent is only *meaningful* once the antecedent holds — which is the
main reason to reach for implication at all.

### Always parenthesise both sides of a `~>`

`~>` is an **arrow** operator, so it binds *tighter* than every comparison. An unparenthesised
comparison consequent gets swallowed, and the result is a silently constant assertion:

```elixir
is_binary(x) ~> String.length(x) <= 10       # parses as (is_binary(x) ~> String.length(x)) <= 10
is_binary(x) ~> (String.length(x) <= 10)     # ✅
```

Elixir compares across all types, so the broken form quietly answers something. Which way it
lands depends on the operator: `p ~> q >= 0` is **always true** (an atom sorts above every
number) and `p ~> q <= 10` is **always false**. Verified on 1.16.0. Recent Elixir emits
`warning: comparison between distinct types found` — worth reading past the generated code in the
message.

`<~` shares the precedence and left-associates, so `A ~> pattern <~ B` parses as
`(A ~> pattern) <~ B`. Write `(x > 0) ~> ({:ok, _} <~ result)`.

### An assertion must be **total**, or your builds disagree

An assertion that raises has neither held nor failed. Bond reports
`Bond.AssertionEvaluationError` rather than a violation, because those are different facts.

```elixir
@pre valid: String.contains?(email, "@")                        # ❌ raises on nil
@pre valid: is_binary(email) and String.contains?(email, "@")   # ✅ total
```

This matters more than it looks. Everywhere else, turning contracts on can only *add* an error.
A partial assertion can turn a call that would have worked into a raise — and `:purge` makes it
disappear again. **That is a behavioural difference between your contracted and purged builds,
which is exactly what contracts must not introduce.**

Watch for: `String.*` on a possibly-`nil` value, `length/1` on a non-list, `map_size/1` on a
non-map, arithmetic on a nullable field, `Enum.*` on something that may not be enumerable.

### Assertions must be pure and cheap

No `Repo.*`, no `GenServer.call`, no `send`, no `IO`/`Logger`, no `:ets`, no HTTP. Two reasons:
assertions run on every call, and under `:purge` they are not compiled at all — so a
side-effecting assertion makes production behave differently from dev.

### Never `rescue` a Bond error to decide what your program does

```elixir
def safe_charge(amount) do
  charge(amount)
rescue
  Bond.PreconditionError -> {:error, :invalid_amount}    # ❌
end
```

With contracts enabled this returns `{:error, :invalid_amount}`. Compiled with
`preconditions: :purge` it returns `{:ok, -5}` — the branch did not get slower, it stopped
existing. A contract violation is the manifestation of a bug, not a business outcome. If the
condition is something your program must handle, it is not a precondition: use ordinary control
flow and return `{:error, _}`.

Catching Bond errors to **report** them (a `Plug.ErrorHandler`, an error tracker) is fine. The
`[:bond, :assertion, :failure]` telemetry event fires on every violation before the raise.

### Contracts are suppressed while an assertion is being evaluated

Meyer's Assertion Evaluation rule, and Bond implements it. Three consequences that surprise
people:

  * A `@pre` on a predicate you call from inside another contract **is silently inert there**. A
    predicate used in assertions has to carry its own weight: keep it simple enough to be
    obviously correct and test it directly.
  * A `@post` may safely **call the function it belongs to** — `@post idempotent: text(result) == result`
    terminates rather than recursing. Put such an assertion last, so cheaper ones fail first.
  * **An `@invariant` is not reachable from another module's assertion.** If module A's `@post`
    calls `B.some_predicate/1`, B's invariant does not come to bear. To enforce a law across a
    module boundary, state it a second time as a public predicate beside the invariant.

### Multi-clause functions: names must agree where a contract references them

One contract applies uniformly to every clause. All clauses must agree on the top-level
parameter name **at each position an assertion references**; positions no contract mentions may
differ freely. A leading underscore does not count — `_now` and `now` agree, so mark unused
parameters `_amount`, not `_amt`.

For shape-dependent assertions across clauses, use `~>`:

```elixir
@pre is_struct(resource, Game) ~> resource.published
@pre is_binary(resource) ~> (String.length(resource) > 0)
```

If a head destructures and the body uses only the fields, prefix the whole-argument binding —
`def matches?(%{id: id} = _api_spec, value)` — and keep referencing the unprefixed name in the
contract. That silences Elixir's unused-variable warning without breaking the contract.

### `where` / `whenever` — destructuring with full assertion syntax

```elixir
# `where` uses `=`: a non-match is a violation.
@post where({:noreply, %{keys: keys, timer: timer}} = result),
      timer_ref: is_reference(timer)

# `whenever` uses `<-`: a non-match is vacuously satisfied.
@post whenever({:ok, %{urls: urls}} <- result),
      non_empty: urls != [],
      all_https: forall(u <- urls, String.starts_with?(u, "https"))
```

  * The keyword and the arrow must match; a mismatched pair is a compile error.
  * **Case analysis is one `whenever` per shape** — no `or {:error, _}` boilerplate, and each
    line gets its own label.
  * The first argument **must be a binding form**. `whenever(is_float(result), ok: ...)` is
    rejected. For "assert only when this holds", the operator is what you want:
    `@post ok: is_float(result) ~> (result >= 0.0)`.
  * They are recognised only at the **start** of a contract — never inside `~>`, `or`, or a
    larger expression. When you need that, either use `match?/2` with a `when` guard, or split
    into two assertions and push the antecedent inward.
  * If a bound name shadows a parameter, Elixir warns "unused variable". The contract is still
    correct; rename one of them.

### Invariants: which heads and which returns

**On entry**, only when the head gives Bond something to bind:

| Head | Checked? |
| --- | --- |
| `def f(%__MODULE__{} = name, ...)` | yes |
| `def f(x, ...) when is_struct(x, __MODULE__)` | yes |
| `def f(%__MODULE__{field: v}, ...)` (destructure-only) | yes |
| `def f({:wrapped, %__MODULE__{} = name})` (nested, bound) | yes |
| `def f({:wrapped, %__MODULE__{field: v}})` (binds nothing) | **no** |
| `def f(x, ...)` (no pattern, no guard) | **no** |
| `defp` anything | no — private functions are exempt |

**On exit**, the return value is checked only when it is `%__MODULE__{}` or
`{:ok, %__MODULE__{}}`. A struct returned in **any other tuple shape is not checked** —
`{batch, struct}` is a common Elixir shape and silently skips the exit check, so the *last* call
of a sequence (the value the caller keeps) is never validated. Verified against 1.16.0. If your
function returns the struct under a different wrapper, restate the law as a `@post`:

```elixir
@post whenever({_batch, updated} <- result, partitioned: partitioned?(updated))
```

Two more:

  * **Give `defstruct` defaults that satisfy the invariant.** `%MyStruct{}` is valid syntax for
    anyone; with `nil` defaults the first invariant to touch it raises
    `Bond.AssertionEvaluationError` rather than reporting a violation. Write
    `defstruct items: [], capacity: 0`, not `defstruct [:items, :capacity]`.
  * **A predicate that tests the invariant must take a bare parameter.** A `%__MODULE__{} = v`
    head gets an entry check, the entry check evaluates the invariant, and the invariant is the
    very thing the predicate exists to test — so it raises on exactly the values it should
    identify and can never answer `false`. Suppress the resulting linter warning with a comment
    saying why.

### `old/1` is meaningful only for state that changes, and only when nothing can interleave

For an immutable parameter `x`, `old(x) == x` is a tautology. And if `old(expr)` reads state
another process can write — an `Agent`, a `GenServer.call`, a shared ETS table, a database — a
concurrent write lands between the snapshot and the check and **the assertion accuses correct
code**. That is the worst failure a contract can have: it teaches you to distrust the contract
rather than the program.

Under sharing, assert only what survives interleaving:

```elixir
@post count_increased: get_count(agent) > old(get_count(agent))    # ✅ honest
@post incremented_by_1: get_count(agent) == old(get_count(agent)) + 1   # ❌ races
```

The strong version belongs somewhere it is true. Either move the pure transformation into its
own module (the before-state arrives as an argument, the after-state is `result`, and you no
longer need `old` at all), or — for a `GenServer` — use `Bond.Server`, where callbacks are
serialized and the strong assertion is sound:

```elixir
defmodule Counter do
  use GenServer
  use Bond.Server        # AFTER use GenServer

  @state_invariant      non_negative: state.count >= 0
  @transition_invariant monotonic:    new_state.count >= old_state.count
end
```

`@state_invariant` is checked on the state a callback **returns** (not the one passed in);
`@transition_invariant` relates `old_state` to `new_state`. Note that a violation raises *inside*
the server, the supervisor restarts it, and **a test suite can stay green while an invariant
fails on every message** — so these are diagnostics unless something asserts on them.

### Errors report the function that ran

A default argument (`def sqrt(x, opts \\ [])`) generates clauses for both arities; the contract
attaches to the higher one, so failures report `sqrt/2` even when the caller wrote `sqrt(-1)`.

With layered contracts (nesting, inheritance, refinement), violations fail-fast in **execution**
order: preconditions outer-first, postconditions **inner-first**. A `@post_strengthen` that seems
inert is usually being pre-empted by an inner callee's own `@post`.

## What to put in a contract

The full treatment is the `writing-bond-contracts` skill. The short version:

**The test is mechanism versus meaning**, not "does it restate the body".

```elixir
@post mapped: result == Enum.map(xs, &transform/1)      # ❌ mechanism — names the algorithm
def process(xs), do: Enum.map(xs, &transform/1)

@post definition: result == (stack.count == stack.capacity)   # ✅ meaning — a property
def full?(%Stack{} = stack), do: stack.count == stack.capacity
```

The first must change whenever the implementation does, because it *is* the implementation. The
second survives any correct rewrite, and Bond publishes it to every reader of your docs. If you
cannot describe an assertion without describing how the function works, it is mechanism.

**Do not write** — and each of these is either unsound, unreachable, or not something the
specification says:

  * **A type check, where the type is the whole of what you would be saying** — use `@spec`.
    ExDoc renders it more prominently, Dialyzer checks it, and it costs nothing at runtime. But
    `@spec` is *static* and never runs, so this is a division of labour rather than a ban: where
    the value arrives at runtime from outside the compiler's view — parsed input, a provider
    payload, a message from another process — or where violating it produces a confusing crash
    somewhere else, a `@pre` is the one that actually fires, and it names the caller. A type check
    carrying a further constraint (`is_integer(n) and n > 0`) was never in question.
  * **A `@pre` a guard already enforces.** Bond reproduces your `when` guards on the wrapper
    clauses, so a failing argument raises `FunctionClauseError` *before* any precondition runs —
    the assertion is unreachable. *Which* side to drop is Meyer's **Non-Redundancy Principle**,
    and it splits three ways: a guard that **selects a clause** is dispatch — keep it, write no
    `@pre`; a guard **standing in for a type** (`when is_binary(email)`) is Elixir's declared
    parameter type — keep it, and put the fact in a `@spec`; a guard **stating a domain rule**
    (`when amount <= account.balance`) is the only redundant case, and there you **pick one** —
    if a violation is the caller's bug, write the `@pre` and drop the guard, because only the
    contract names the caller, renders into the docs, and appears in the coverage table. **Apply
    the purge test below before dropping anything**: a guard whose absence changes what the
    program *does* is load-bearing, and a `@pre` cannot replace it. A `@pre` **stronger** than the
    guard is not redundant at all: it can fail, so keep it as it stands.
  * **Assertions about data from outside your system.** A provider sending nonsense is not a
    programming error, and a `@post` that raises on it converts their bad data into your crash.
    At a parsing boundary, **assert what you emit, never what you received.**
  * **A precondition your caller cannot evaluate.** A public function's `@pre` must not call a
    `defp` — Bond warns, citing Meyer's Precondition Availability rule. `@doc false` on the
    predicate defeats it the same way, because the obligation is published in terms the reader
    cannot look up. The fix is almost always to **publish the predicate**, not to drop the
    obligation — if it is fit to demand, it is fit for the caller to read. Postconditions are
    exempt either way: they are the function's promise, not the caller's obligation.

**Not on that list: "every current caller already gets this right."** A precondition is an
obligation on every *future* caller, so a contract no existing call site violates is the normal
case, not a redundant one — that is what a green suite looks like. Decide from the specification,
not from a census of today's callers.

### The purge test, before converting existing code into a contract

Everything above is about what to write from scratch. **Converting a check that already exists is
a different move with a different failure mode**, and it is the one you make constantly while
sweeping a codebase. One question settles it:

> Under `:purge`, would this change what the program **does**, or only what it **notices**?

Only what it notices → contract. What it does → ordinary code, unconditional in every build.
`@pre`, `@post`, `@invariant` and `check/1` are all purgeable; a refusal your program must always
perform is not one of them.

```elixir
# The provider comes from a form. A mismatch is a FORGED REQUEST, not a caller's bug.
true = Enum.any?(socket.assigns.connections, &(&1.provider == atom))

@pre connected_to_that_provider: ...   # ❌ purged, and the forgery is accepted
```

**The tell is not how the check is written — it is what happens if it is not there.**
`true = Enum.any?(...)` has no `case`, no `{:error, _}`, nothing shaped like control flow, so a
sweep reads it as a contract someone wrote before they had Bond. What settles it is where the
value came from: data from outside your system has no caller of yours to blame, so refusing it is
behaviour, not diagnosis.

This is the inverse of *never rescue a Bond error to decide what your program does*, and the
direction that bites during an audit: **don't convert what the program does into something it
merely notices.**

When a load-bearing check cannot become a `@pre`, there is often still a `@post` worth having
beside it — keep the refusal as ordinary code with a diagnostic that names the rule, and let the
contract claim something purging cannot weaken (what the function *returns*, where the body
validates what it *looked up*).

**Non-Redundancy assumes the two checks are the same check.** Before deleting either side of an
apparent duplicate, remove it and ask what stops being true, in *every build you ship*.
"Redundant" is a conclusion, not an observation: two checks that read alike may be an accident,
a deliberate second line of defence (`bond:testing`), or a purgeable thing standing in front of
one that is not. Only the first is redundancy.

**Do write** laws that are true of the *meaning*: conservation (`length(result) <= length(input)`,
or comparing sorted multisets rather than appealing to uniqueness), relationships between two
implementations of one rule (a query and the predicate that should agree with it), units and
magnitudes that are not type errors (`@pre skew_under_a_day: skew <= 86_400` catches milliseconds
passed as seconds), and values that are silently poisonous downstream.

## Configuration

Four kinds — `:preconditions`, `:postconditions`, `:invariants`, `:checks` — each `true`
(default), `false` (compiled in, inert, runtime-togglable), or `:purge` (not compiled at all).

```elixir
# config/prod.exs — a good default posture
config :bond,
  preconditions: true,     # cheapest kind, and the only one that names a CALLER's bug
  postconditions: false,   # compiled in but inert — enable from a remote console mid-incident
  invariants: false,
  checks: false
```

  * **The chain is `preconditions ≤ postconditions ≤ invariants`.** Purging a lower kind requires
    purging every kind above it, or it is a compile error. Disabling a lower kind at runtime
    skips the higher ones too.
  * **Prefer `false` to `:purge`** unless you are on a genuinely hot path. `false` costs one
    lock-free `:persistent_term` read per kind per call, and it keeps the option of switching
    checks on in production. `:purge` also **orphans anything that existed only to serve an
    assertion** — an `import Bond.Predicates`, a `defp` predicate — which fails a release built
    with `--warnings-as-errors`. If you do purge, compile that config in CI.
  * **An assertion must be sound, not merely inert.** "It is off in production" is not a licence
    to write one that could accuse correct code — anyone can switch it on.
  * `Application.put_env(:bond, ...)` after the first contracted call **has no effect**; the
    state is cached. Use `Bond.Config.enable/1` / `disable/1`, or `Bond.Config.reset/0`.
  * Per-module: `use Bond, preconditions: :purge` or `config :bond, overrides: [{Mod, opts}]`.

## Where contracts go

Every layer has a specification, so every layer can carry a contract. What changes between them is
**which kind** the specification warrants — not whether the module deserves one.

| Layer | What the specification usually warrants |
| --- | --- |
| Domain structs, parsers | All three — external data lands here, poison values start here |
| Behaviour `@callback`s | All three, **declared once** — inherited by every implementation |
| Pure core / transformation modules | `@post` above all — the interesting laws live here |
| HTTP clients, adapters facing a service you don't control | `@post`, rarely `@pre` — assert what you *emit*, stay tolerant about what arrives |
| Persistence contexts | `@pre` for what a caller must supply; the type's own laws belong on the struct |
| Controllers / LiveViews | `@post` / `@invariant` over the state you assign — usually the thinnest layer, so there is least to say, not least worth saying |

The seam matters: **the postconditions of your filter modules must match or exceed the
preconditions of the modules behind them.**

Two things that are *not* reasons to leave a layer uncontracted:

  * **"A violation there would be a 500."** That is a configuration question, and Bond already
    answers it: ship that kind as `false` and the assertion is compiled in, inert, and switchable
    from a remote console mid-incident. An *unsound* assertion is a reason not to write one; an
    expensive failure mode is only a reason to choose where it runs.
  * **"This layer is a filter, so it should be tolerant."** Tolerance is a statement about `@pre`
    — whether bad input is the caller's bug or a normal outcome to return. It says nothing about
    `@post`, and a filter's postconditions are precisely what the demanding domain behind it is
    relying on.
