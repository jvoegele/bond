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

The two libraries are conceptually complementary, but they can't share a
module: both override `Kernel.@/1`, and Elixir refuses to pick a winner
(see [the next FAQ entry](#can-i-use-bond-and-norm-in-the-same-module)).
You can still call Norm's validation helpers from a Bond module as
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

**No.** `use Bond` and `use Norm` in the same module fails to compile
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

The same applies to any other library that overrides `Kernel.@/1`. In
practice, very few do — overriding `@/1` is an invasive technique.
Standard attribute-based libraries (Ecto's `schema/2`, TypedStruct,
etc.) work fine alongside Bond.

### Recommended workaround: split into separate modules

Use each library in its own module and have one call into the other:

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
on the `Norm` module — no `use Norm` required:

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
or wrong, and contracts *are* that oracle. `Bond.PropertyTest.contract_holds/2`
exposes this directly with two shapes:

```elixir
use Bond.PropertyTest

# Form 1: random inputs into a single function
contract_holds &Math.sqrt/1, args: [StreamData.float(min: 0.0)]

# Form 2: random sequences over a struct's @invariant
contract_holds BoundedStack,
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

If your function doesn't pattern-match the struct at all (no struct in
the head, no guard mentioning it), invariants are silently skipped for
that function. The other contract kinds still apply. Bond emits a
compile-time warning when it detects this case — see the next entry.

Violations raise `Bond.InvariantError` and emit `[:bond, :assertion, :failure]`
telemetry with `:kind => :invariant`. See the
[Invariants](Bond.html#module-invariant-for-struct-modules) section in the
moduledoc.

## Why is Bond warning that my function "matched no struct parameter"?

You're seeing something like:

```
public function `update/2` in invariant-declaring module
`MyApp.BoundedStack` matched no struct parameter; invariants are not
checked here. If intentional, suppress with `use Bond,
warn_unmatched_invariant_subject: false` (per module) or `config :bond,
warn_unmatched_invariant_subject: false` (globally).
```

Bond emits this at compile time when a public function (`def`, not
`defp`) in an invariant-declaring module has no clause whose head
pattern-matches the struct. Without a matching head, Bond has no
`subject` to bind, so invariants are silently skipped for that
function — and "silently skipped" was the footgun before this warning
existed.

**If the function is supposed to operate on the struct**, the fix is
usually a missing pattern or guard:

```elixir
# Footgun — head doesn't match the struct, so the @invariant doesn't fire here:
def update(stack, x), do: ...

# Fixed — Bond detects the struct and the @invariant fires:
def update(%__MODULE__{} = stack, x), do: ...
# or:
def update(stack, x) when is_struct(stack, __MODULE__), do: ...
```

See "When does Bond check invariants?" above for every shape Bond
detects.

**If the function is genuinely not about the struct** (a utility
function in the same module, an alternate constructor, etc.), suppress
the warning explicitly. Per module is the usual choice:

```elixir
use Bond, warn_unmatched_invariant_subject: false
```

If most of your invariant-declaring modules legitimately have mixed
struct and non-struct public functions, suppress globally instead:

```elixir
# config/config.exs
config :bond, warn_unmatched_invariant_subject: false
```

The warning is opt-out so the footgun is caught by default; both
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
