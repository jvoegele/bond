# Frequently Asked Questions

## Why contracts when I have ExUnit?

Tests verify behaviour for the specific scenarios you've written. Contracts
verify behaviour on **every call** in the running system. They catch
violations you didn't think to test for, especially in long-running dev or
staging environments. Tests and contracts complement each other:

- Tests describe what your code *should* do.
- Contracts describe what your code *must always be true while doing*.

For functions that are easy to test and have well-known input shapes,
tests alone are usually fine. For functions whose preconditions are
nuanced or whose results have invariants that span many call sites,
contracts catch bugs sooner with less work.

## Will contracts slow down my production code?

Not if you `:purge` them. Bond supports
[compile-time conditional compilation](Bond.html#module-conditional-compilation):

```elixir
# config/prod.exs — strip contracts entirely from this build
config :bond,
  preconditions: :purge,
  postconditions: :purge,
  checks: :purge
```

When both `:preconditions` and `:postconditions` are `:purge`d for a
function, Bond emits no override at all and the function runs with zero
per-call overhead. The compiled BEAM contains no contract evaluation code
for that function.

A typical pattern: contracts on in dev/test, `:purge`d in prod.

For concrete numbers — how many nanoseconds each contract kind adds per
call, and how much compile time Bond costs per module — see the
[Overhead](overhead.md) guide. Headline figures from the reference
environment: a `:purge`d contract is free; an enabled `@pre` adds ~130
ns/call; an enabled `@invariant` (entry + exit) adds ~440 ns/call; Bond
compile-time overhead is ~10 ms per module that uses contracts.

## Can I toggle contracts at runtime without recompiling?

Yes — that's what `true` and `false` (as distinct from `:purge`) give you.
When a kind is compiled with `true` or `false`, the override has a runtime
guard:

```elixir
# In IEx or a remote console:
Application.put_env(:bond, :preconditions, false)  # dormant
Application.put_env(:bond, :preconditions, true)   # active again
```

The runtime check is a single `Application.get_env/3` lookup per call. For
inner-loop hot paths, `:purge` is still the right choice — runtime toggle
costs a tiny lookup; `:purge` costs nothing.

## Can I disable contracts for one specific module?

Yes, two ways.

In the source:

```elixir
defmodule MyApp.HotPath do
  use Bond, preconditions: :purge, postconditions: :purge
end
```

Or in config (handy when you don't want to touch the source):

```elixir
config :bond,
  overrides: [
    {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
    {~r/Workers\./, postconditions: false}
  ]
```

Exact module atoms match precisely. `Regex` patterns match against the
source-visible module name. The `use Bond` opts override `:overrides`,
which override the global config.

## How does Bond compare to Norm?

[Norm](https://github.com/elixir-toniq/norm) validates **data shapes** — a
value matches a spec or it doesn't. Bond verifies **function behaviour** —
a contract asserts something about the relationship between inputs,
outputs, and (optionally) prior state.

The two libraries are conceptually complementary. By default they can't
share a module — both override `Kernel.@/1` — but Bond's `at_annotations: false`
escape hatch lets them coexist, including on the same function (see
[the next FAQ entry](#can-i-use-bond-and-norm-in-the-same-module)).
You can also call Norm's validation helpers from a Bond module as
ordinary remote calls:

```elixir
defmodule MyApp.Boundary do
  use Bond

  @pre matches_input_spec: Norm.valid?(input, MyApp.Specs.input())
  @post matches_output_spec: Norm.valid?(result, MyApp.Specs.output())
  @post "no items lost": length(result) == length(input)
  def transform(input), do: ...
end
```

…where `MyApp.Specs` is a separate module that does `use Norm` and
defines `input/0` and `output/0` with Norm's `spec/1`.

## Can I use Bond and Norm in the same module?

**Yes — pass `at_annotations: false` to `use Bond`.**

By default, `use Bond` and `use Norm` in the same module fail to compile
with:

```
function @/1 imported from both Bond and Norm.Contract, call is ambiguous
```

Both libraries use the same technique to intercept module attributes:
`import Kernel, except: [@: 1]` followed by importing their own `@/1`
macros. When both `use` lines land in one module, both imports end up
at the same scope level — Elixir does not pick a winner — and the first
`@`-using line fails. The error is loud and points at the offending
line; contracts are never silently dropped.

### The escape hatch: `use Bond, at_annotations: false`

`at_annotations: false` tells Bond to leave `Kernel.@/1` untouched in that
module, so Norm keeps ownership of `@` (and thus `@contract`). Bond's
compiler hooks are still installed, but you write Bond contracts as
fully-qualified calls — `Bond.pre/1`, `Bond.post/1`, and `Bond.invariant/1`.
`check/1` remains available unqualified.

```elixir
defmodule MyApp.Boundary do
  use Norm
  use Bond, at_annotations: false

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  # Guarded by Norm's @contract AND Bond's precondition — the two wrappers
  # compose, each delegating to the next via `super`.
  @contract scale(n :: positive_int()) :: positive_int()
  Bond.pre even: rem(n, 2) == 0
  def scale(n), do: n * 2

  # A Bond-only function in the same module.
  Bond.pre positive: x > 0
  Bond.post result == x * 2
  def double(x), do: x * 2
end
```

The bare `pre`/`post`/`invariant` macros are **never** imported — even
under the default `at_annotations: true` — so they can't collide with common
function names like `post`. They're reachable only as `Bond.pre`,
`Bond.post`, and `Bond.invariant`. Note that the formatter writes
qualified calls with parentheses (`Bond.pre(x > 0)`); this is why the
`@pre` form remains the recommended, more readable default for modules
that don't need to coexist with another `@`-overriding library.

### Limitation: at most one `@contract` per module

Norm's `@contract` does two things: it wraps the contracted function
(via `defoverridable`), and it emits a small `def __contract__/1` helper
clause — one per `@contract`. Bond [tolerates the override
clause](#can-i-use-bond-with-decorator-or-other-libraries-that-wrap-functions),
but two or more `@contract`s produce non-adjacent `__contract__/1` clauses
that still trip Bond's clause-grouping check. If you need more than one
Norm contract alongside Bond, split into separate modules (below) or keep
the extra contracts in a Norm-only module.

### Alternative: split into separate modules

Each library in its own module, one calling the other — always works, and
sidesteps both the `@` clash and the multiple-`@contract` limit:

```elixir
defmodule MyApp.Specs do
  use Norm

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  @contract validate(n :: positive_int()) :: positive_int()
  def validate(n), do: n
end

defmodule MyApp.Worker do
  use Bond

  @pre is_integer(n)
  @post result == n * 2
  def double(n) do
    n = MyApp.Specs.validate(n)
    n * 2
  end
end
```

### Alternative: use Norm's data helpers without `use Norm`

If you only need Norm's data-shape helpers (`spec/1`, `conform/2`,
`valid?/2`) inside a Bond module, call them as ordinary remote calls
on the `Norm` module — no `use Norm` required, so you keep the `@pre`
syntax:

```elixir
defmodule MyApp.Worker do
  use Bond

  @pre positive: Norm.valid?(n, positive_int_spec())
  def double(n), do: n * 2

  defp positive_int_spec, do: Norm.spec(is_integer() and (&(&1 > 0)))
end
```

This keeps Bond's `@/1` interception intact and uses Norm only for
spec construction and validation.

## Can I use Bond with `decorator` or other libraries that wrap functions?

**Yes.** Libraries that wrap functions — the
[`decorator`](https://github.com/arjan/decorator) library, Norm's
`@contract`, and similar — do so by making the function `defoverridable`
and redefining it to call the original via `super`. That redefinition
fires Bond's `@on_definition` callback, so Bond used to see the function
defined twice and reject it ("clauses ... must be grouped together").

Bond now detects these externally-generated override clauses (a clause
that is `defoverridable` at definition time is a wrapper, not a hand-written
clause) and ignores them for tracking purposes. Bond still wraps the
function as a whole with its own contract check, composing with the other
library's wrapper through `super`:

```elixir
defmodule MyApp.Job do
  use MyApp.Telemetry   # a decorator-style library that wraps functions

  use Bond

  @decorate timed()
  @pre valid: is_map(args)
  def perform(args), do: run(args)
end
```

Here a call to `perform/1` runs Bond's precondition, then the telemetry
wrapper, then the original body. The only requirement is that contracts
attach to your hand-written clause — which is the normal case; you don't
write the wrapper, the other library generates it.

This tolerance only changes a situation that previously always raised a
compile error, so it can't affect code that already compiled.

## Why can't I have postconditions on while preconditions are off?

Because a postcondition failure when preconditions weren't checked is
diagnostically misleading — it might really be the caller's fault, not
the function's. Bond's contract-checking chain says:

```
preconditions ≤ postconditions ≤ invariants
```

Concretely:

- **Compile-time:** if you `:purge` a lower kind, you must `:purge`
  every higher kind too. `config :bond, preconditions: :purge` while
  leaving `:postconditions: true` is a compile error.
- **Runtime:** if you `Application.put_env(:bond, :preconditions, false)`,
  postconditions and invariants are also skipped automatically. Bond
  emits a one-time `Logger.warning` per process per (higher, lower)
  pair so you know it happened.

`:checks` is independent of the chain — `check/1` is an internal
sanity assertion, not a contract with a caller.

If you genuinely want to skip a higher kind's *evaluation* without
removing the code, use `false` instead of `:purge` (compiled in,
runtime-disabled by default; flippable via `Application.put_env/3`).

## How do I disable a single failing contract while debugging?

Bond intentionally has no per-contract on/off knob. The contract toggles
that exist are coarser by design — per-kind (`:preconditions`,
`:postconditions`, `:invariants`, `:checks`) and per-module (via
`:overrides` or `use Bond` options) — because a contract is part of a
function's stated agreement with its caller, and adding a fourth axis of
"this individual assertion is off" tends to mask broken agreements
rather than resolve them. For debugging, pick whichever of these fits:

1. **Comment it out.** Simplest, and the right answer most of the time.
   Add a `TODO` so it doesn't stay commented past the debugging session.
2. **Move the assertion to `check/1` inside the body.** `check/1` is
   wrappable in a conditional and is the right home for an assertion
   you want to gate on runtime state (e.g. a feature flag) rather than
   on contract policy.
3. **Disable the kind globally for the relevant environment.** If you're
   investigating a precondition storm in dev, `config :bond,
   preconditions: false` in `config/dev.exs` skips all preconditions at
   runtime without recompiling consumers. Heavy-handed but cheap. The
   chain rule (preconditions ≤ postconditions ≤ invariants) means
   disabling preconditions also skips the higher kinds; see "Why can't
   I have postconditions on while preconditions are off?" for why.

## What does Bond do that typespecs don't?

Typespecs are static documentation of input and output **types**. Tools
like Dialyzer can verify them statically, but typespecs cannot express:

- Relationships between arguments (`amount <= balance`).
- Relationships between input and output (`result <= balance`).
- Conditional invariants (`(x == 0) ~> (result == 0.0)`).
- State-change properties using `old/1`.
- Arbitrary computed predicates.

Typespecs say "this argument is an integer." Contracts say "this argument
is a positive integer less than the balance, and the result is the
balance minus the argument." Use both.

## Are contracts evaluated on the recursion path?

No — Bond implements Bertrand Meyer's
[Assertion Evaluation rule](https://en.wikipedia.org/wiki/Design_by_contract):

> During the process of evaluating an assertion at run-time, routine
> calls shall be executed without any evaluation of the associated
> assertions.

If a postcondition calls another contracted function, that inner
function's preconditions and postconditions are *not* evaluated. Without
this rule, mutually recursive contracts would loop forever. With it,
contracts are safe to use even when they call into the rest of your API.

## Can I use `check/1` to assert input validity?

No — `check/1` is for **sanity checks during development**, not input
validation. A `check` can be compiled out entirely via
`config :bond, :checks, false`, and the wrapped expression is then not
evaluated at all. If your code's correctness depends on something being
checked, use ordinary control flow:

```elixir
# DON'T: relies on check for correctness
def withdraw(balance, amount) do
  check amount > 0
  balance - amount
end

# DO: explicit guard, evaluated regardless of config
def withdraw(balance, amount) when amount > 0 do
  balance - amount
end
```

## Why does my error message report `sqrt/2` when I wrote `sqrt/1`?

If the function has a default argument, like
`def sqrt(x, trap_door \\ nil)`, Elixir generates clauses for both arities
(`sqrt/1` and `sqrt/2`). Bond attaches the contract to the higher-arity
clause, so error messages report `sqrt/2` even when the caller writes
`Math.sqrt(-1)` (which Elixir dispatches via the auto-generated `sqrt/1`
forwarder).

This is expected. If you want the error to mention `sqrt/1`, split the
default-arg form into explicit clauses.

## How does Bond compose with StreamData / property-based testing?

Contracts and property-based testing are natural partners: PBT's hard
part is usually writing the oracle that says whether an output is right
or wrong, and contracts *are* that oracle. `Bond.PropertyTest` exposes
this directly with two macros:

```elixir
use Bond.PropertyTest

# contract_holds/2: random inputs into a single function
contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

# invariants_hold/2: random sequences over a struct's @invariant
invariants_hold BoundedStack,
  constructors: [{:new, [StreamData.integer(1..100)]}],
  transformers: [{:push, [StreamData.term()]}, {:pop, []}]
```

`stream_data` is an optional dep of bond — add it to your own project
when you want PBT. See the
[Property-based testing](Bond.html#module-property-based-testing) section
in the moduledoc.

## When does Bond check invariants?

`@invariant` declarations on a struct module are checked automatically at
the boundaries of that module's public functions. Bond auto-detects the
struct parameter in the function head and pre-checks against it:

- **On entry**, when the function head matches the struct in any of these
  shapes (Bond detects all three):
    - `def foo(%__MODULE__{} = name, ...)` — explicit pattern with binding.
    - `def foo(x, ...) when is_struct(x, __MODULE__)` — bare param plus
      guard (including arbitrary nesting inside `and` / `or`).
    - `def foo(%__MODULE__{field: v}, ...)` — destructure-only. Bond
      rewrites the override clause to capture the struct under a
      generated name so the pre-check still fires.
- **On exit**, against the return value if it's `%__MODULE__{}` or
  `{:ok, %__MODULE__{}}`. Other return shapes fall through without a
  check. If your function wraps the struct differently, add an explicit
  `@post`.
- **For multi-struct heads** like `def merge(%__MODULE__{} = a,
  %__MODULE__{} = b)`, both parameters are checked in left-to-right
  order, with the implicit `subject` rebinding to each in turn.
- **Never for `defp`** — private functions are exempt by the Eiffel
  convention (they often hold transiently-invalid state mid-operation).

If a function has neither a struct-matching head **nor** a return
value Bond recognises as the struct (a literal `%__MODULE__{}` or
`{:ok, %__MODULE__{}}`), both the on-entry and on-exit checks are
skipped — invariants don't fire for that function at all. The other
contract kinds still apply. Bond emits a compile-time warning when it
detects this case — see the next entry.

Violations raise `Bond.InvariantError` and emit `[:bond, :assertion, :failure]`
telemetry with `:kind => :invariant`. See the
[Invariants](Bond.html#module-invariant-for-struct-modules) section in the
moduledoc.

## Why is Bond warning about skipped invariants?

You're seeing something like:

```
public function `update/2` in invariant-declaring module
`MyApp.BoundedStack` has no clause that pattern-matches the struct or
returns one; invariants are skipped here. If intentional, suppress
with `@bond_warn_skipped_invariants false` (per function), `use Bond,
warn_skipped_invariants: false` (per module), or `config :bond,
warn_skipped_invariants: false` (globally).
```

Bond's invariants fire in two places: on entry (when the function head
pattern-matches the struct, giving Bond a `subject` to bind) and on
exit (when the return value is a literal `%__MODULE__{}` or
`{:ok, %__MODULE__{}}`). Bond warns when a public function (`def`, not
`defp`) in an invariant-declaring module has **neither** mechanism —
neither a struct-matching head nor a statically-detectable struct
return. In that case both the on-entry and on-exit checks are skipped,
and the function silently bypasses invariants entirely.

The detection is intentionally conservative on the post-side: only the
literal shapes `%__MODULE__{...}` and `{:ok, %__MODULE__{...}}` (or
the same as the last expression of a block) suppress the warning.
Functions that build the struct via a helper call (`def from_map(m),
do: build(m)`) still warn, because Bond can't tell statically that the
helper returns a struct — use per-function suppression there.

A **build-style constructor** that assembles the struct in a variable
and returns it wrapped trips this too:

```elixir
def build(opts) do
  state = %__MODULE__{count: opts[:count]}
  {:ok, state}   # Bond sees `{:ok, <variable>}`, not a literal struct
end
```

The runtime post-check still fires on the returned value, so the
invariant *is* enforced — the warning only means Bond couldn't prove it
statically. This is the common shape for an `invariants_hold/2` target's
constructor, so expect the warning there and suppress it per function
with `@bond_warn_skipped_invariants false`.

**If the function is supposed to operate on the struct**, the fix is
usually a missing pattern or guard on the head:

```elixir
# Footgun — head doesn't match the struct, body doesn't return one:
def update(stack, x), do: Map.put(stack, :counter, x)

# Fixed — Bond detects the struct on entry and the @invariant fires:
def update(%__MODULE__{} = stack, x), do: Map.put(stack, :counter, x)
# or:
def update(stack, x) when is_struct(stack, __MODULE__), do: ...
```

See "When does Bond check invariants?" above for every shape Bond
detects on entry, and the shapes it recognises on exit.

**If the function is genuinely not about the struct** (a utility
function, a class-name helper, a constructor whose body Bond can't
statically read as a struct return), suppress the warning at the right
scope. From narrowest to broadest:

```elixir
# Per function — only this def. Other public functions in the same
# module keep the safety net.
@bond_warn_skipped_invariants false
def class_name, do: "Stack"
```

```elixir
# Per module — every public function in the module is exempt. Useful
# when the whole module legitimately doesn't operate on the struct
# (rare; reconsider whether @invariant belongs here at all).
use Bond, warn_skipped_invariants: false
```

```elixir
# Global — every module in the project. Use sparingly; you lose the
# footgun-catcher everywhere.
# config/config.exs
config :bond, warn_skipped_invariants: false
```

**Per-function is the right answer most of the time.** A typical
struct module has a few utility or constructor functions mixed in with
the struct-operating ones, and you want the warning to keep firing on
the latter if they're later refactored to drop the struct from their
head. Module-level suppression silences future regressions in the same
module, so reach for it only when you mean "this entire module isn't
about the struct."

The per-function override is a tri-state: omitting the attribute
inherits the module/global setting; `false` suppresses for that one
def; `true` re-enables the warning even under a module/global `false`
— useful for selectively opting back in to verify a specific
function under a project-wide suppression.

The warning is opt-out so the footgun is caught by default; all three
suppression knobs ship with 1.0 and are part of the public API.

## How are multi-clause functions handled?

A single contract applies **uniformly to every clause** of a multi-clause
function. Put your `@pre` and `@post` annotations before the first clause;
Bond emits one wrapper clause per user clause (each preserving the user's
pattern so Elixir's natural pattern-matching dispatch survives) and one
set of lifted assertion defps that all wrappers delegate to.

```elixir
@pre is_list(input)
@post is_atom(result)
def parse([:a | _]), do: :starts_with_a
def parse(input) when is_list(input), do: :other
```

Contracts must apply uniformly across clauses, so **all clauses must agree
on the top-level parameter name at each position** when Bond is wrapping
the function. The wrapper uses that name when it calls `super` and when
it passes arguments to the lifted contract defps — the names referenced
in your assertion expressions are the canonical names.

Heterogeneous naming raises a `CompileError`:

```elixir
defmodule MyMod do
  use Bond

  @pre conn != nil
  def lookup(conn, %Game{} = g, %GameFilm{} = f), do: ...
  def lookup(conn, league, conference) when is_binary(league), do: ...
  #             ^^^^^^                 ^^^^^^^^^^
  # CompileError: positions 1 and 2 disagree on top-level names
  # (`g` vs `league`, `f` vs `conference`)
end
```

The fix is to rename for consistent positional meaning across clauses —
usually a readability improvement too, since the original names described
one shape but the function accepts multiple:

```elixir
@pre conn != nil
def lookup(conn, %Game{} = resource, %GameFilm{} = scope), do: ...
def lookup(conn, resource, scope) when is_binary(resource), do: ...
```

For **shape-dependent** assertions, use the `~>` implication operator
from `Bond.Predicates`. It short-circuits the consequent when the
antecedent is falsy, so the consequent only runs for the shape it
applies to:

```elixir
@pre is_struct(resource, Game) ~> (resource.published)
@pre is_binary(resource) ~> (String.length(resource) > 0)
def lookup(conn, %Game{} = resource, scope), do: ...
def lookup(conn, resource, scope) when is_binary(resource), do: ...
```

Wildcard clauses (`def f(_)`) and literal-pattern clauses (`def f(0)`)
don't bind a top-level name at that position. They adopt whatever name a
sibling clause provides — Bond rewrites the wildcard or wraps the literal
to bind the canonical name in the wrapper's pattern.

**Underscore-prefixed names are equivalent to their unprefixed forms.**
A fallback clause like `def f(_a, _b, c)` paired with a contracted clause
`def f(a, b, c)` agrees on the canonical names `a`, `b`, `c` — Elixir's
leading-underscore convention is "bound but intentionally unused," and
Bond treats `_a` and `a` as the same binding for the consistency check.
Write fallback clauses with `_name` markers freely; the contracts still
attach.

### Naming consistency is only required where contracts depend on it

The naming-agreement rule applies *positionally*: only positions whose
top-level names are *referenced* by some assertion need to agree across
clauses. A contract that doesn't reference any parameter — for example
`@post is_boolean(result)` — doesn't constrain naming at all, even on
multi-clause functions whose clauses bind different names at every
position:

```elixir
@post is_boolean(result)
def can_access?(conn, %Game{} = game, %GameFilm{} = film), do: ...
def can_access?(conn, league, conference) when is_binary(league), do: ...
#                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# Positions 1 and 2 disagree on top-level names, but no contract references
# them — Bond doesn't enforce agreement at those positions. The `@post`
# compiles cleanly.
```

If you later add a contract that *does* reference one of the disagreeing
positions, the agreement rule re-engages at that position and the
`CompileError` fires. Trivial contracts (result-only, or referencing only
positions that already agree) are free to attach without first renaming
parameters across clauses.

`Bond.Predicates` helpers like `is_boolean/1` and other Kernel predicates
that take only `result` work as universal contracts on any multi-clause
function regardless of how its parameters are named per clause.

Bond raises a compile error if you put `@pre` or `@post` between clauses
— contracts attach to a function, not a clause:

```elixir
# COMPILE ERROR — contracts must precede the first clause
@pre x > 0
def foo(x) when is_integer(x), do: x * 2

@pre is_float(x)       # not allowed here
def foo(x) when is_float(x), do: round(x)
```

Per-clause contracts are out of scope for Bond 1.0 — by design.
Contracts describe the function's behavioural agreement with its caller,
which is one agreement per function regardless of how many clauses
implement it. If different clauses genuinely have different contracts,
that's a sign they're really two different functions; split them.

When the contract is the same across clauses but a parameter is named
differently in each clause, use a bodyless function head to attach the
contract to a single canonical parameter list, then define the clauses
with whatever names suit each:

```elixir
@pre is_integer(n)
def double(n)

def double(n) when n >= 0, do: n * 2
def double(n), do: -n * -2
```

The "Naming consistency is only required where contracts depend on it"
relaxation (see above) also makes the workaround lighter: cross-clause
agreement is only enforced at parameter positions a contract actually
references.

## How do I reuse a predicate across several functions?

If the same condition guards an argument in several functions, you don't
have to retype the expression each time. Contract expressions are ordinary
Elixir, so the simplest reuse is to **define the predicate as a function**
and call it from each contract:

```elixir
defmodule Mailer do
  use Bond

  @pre valid_recipient: valid_email?(to)
  def send_welcome(to, name), do: ...

  @pre valid_recipient: valid_email?(to)
  def unsubscribe(to), do: ...

  # The reusable predicate — declared once, called from any contract.
  def valid_email?(address) do
    is_binary(address) and String.contains?(address, "@")
  end
end
```

The predicate can be a private `defp`; it still resolves inside contracts
because Bond's checks run in the same module. On failure the error reports
the **call**, not the expanded body:

```
label: :valid_recipient
assertion: valid_email?(to)
```

That named form is exactly what you want when the predicate is gnarly (a
real email regex reads worse than `valid_email?`). When you'd rather see
the **full expanded expression** in errors and docs — and abstract the
*label* along with it — reach for a macro instead.

### Abstracting the label, and inlining the expanded source

Bond renders an assertion by running `Macro.to_string/1` on the surface
AST you wrote, **without macro-expanding it first**. So a macro *call*
inside `@pre` prints as the call (the named form above). To make the
expanded expression show up, write a macro that **emits the whole labelled
`@pre`**:

```elixir
defmodule Contracts do
  use Bond  # <-- required; see the caveat below

  defmacro require_email(name) do
    var = Macro.var(name, nil)

    quote do
      @pre valid_recipient:
             is_binary(unquote(var)) and String.contains?(unquote(var), "@")
    end
  end
end

defmodule Mailer do
  use Bond
  require Contracts

  Contracts.require_email(:email)   # one line per function
  def send(email), do: email
end
```

Now both the label and the expression are abstracted into one reusable
macro, and the error reports the fully expanded contract:

```
label: :valid_recipient
assertion: is_binary(email) and String.contains?(email, "@")
binding: [email: "nope"]
```

The generated `## Contracts` documentation uses the same captured string,
so it shows the expanded expression too. A single macro can emit several
`@pre`/`@post` lines, which lets you abstract over a *group* of labelled
predicates at once.

### Caveat: the predicate macro's module must `use Bond`

This is macro hygiene. The `@` inside `Contracts`'s `quote` resolves in
`Contracts`'s context — so if that module doesn't `use Bond`, its `@pre`
is plain `Kernel.@/1`, which treats `@pre <expr>` as a module-attribute
assignment and *eagerly evaluates* the right-hand side. The symptom is a
compile error like `undefined variable "email"`. Add `use Bond` to the
module that defines the predicate macros and `@pre` resolves to Bond's
override, deferring the expression into the generated check as intended.
(You don't need `var!` — `Macro.var(name, nil)` unifies with the function
parameter on its own.)

## How do I share one contract across every implementation of a behaviour?

Declare the contract on the behaviour's `@callback` with `Bond.Behaviour`,
and have implementers inherit it with `use Bond, behaviours: […]`:

```elixir
defmodule Ledger do
  use Bond.Behaviour

  @pre positive_amount: amount > 0
  @post non_negative: result >= 0
  @callback withdraw(balance :: non_neg_integer, amount :: pos_integer) :: non_neg_integer
end

defmodule BankAccount do
  use Bond, behaviours: [Ledger]

  @impl true
  def withdraw(bal, amt) when amt <= bal, do: bal - amt
end
```

Every implementation enforces the same `@pre`/`@post` without restating them.
Contracts reference the callback's argument names and bind by position, so an
implementation can name its parameters however it likes. A violation is
attributed to the source behaviour (`precondition (inherited from Ledger)
failed for call to BankAccount.withdraw/2`).

By default an implementation inherits its contracts verbatim, and attaching a
plain `@pre`/`@post` to an inherited operation is a compile error. An
implementation may *deliberately* refine a behaviour's contract with
`@pre_weaken` (weakens the precondition) or `@post_strengthen` (strengthens the
postcondition) — Eiffel-style behavioural subtyping. Use `check/1` in the
function body for an implementation-specific assertion independent of the
contract. See the [Contract Inheritance](contract-inheritance.md#behaviours)
guide for the full rules.

> #### Behaviour-level invariants {: .info}
>
> This applies to `@pre`/`@post` on `@callback`s. Struct `@invariant`s remain
> scoped to the struct's own module and compose with inherited contracts
> independently.
