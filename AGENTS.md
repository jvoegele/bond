# AGENTS.md — working on Bond itself

Bond is a Design by Contract library for Elixir: `@pre`, `@post`, `@invariant` and `check/1`
compiled into ordinary functions at macro-expansion time.

**This file is for people (and agents) changing Bond.** If you are *using* Bond in an
application, you want the guides in `guides/` — start with `guides/getting-started.md` — or
`usage-rules.md`, which is the condensed version written for coding agents.

Everything below is something that has already gone wrong at least once. It is not a tour of
the codebase; it is the set of facts that are expensive to rediscover.

---

## Commands

```sh
mix test                              # 1185 tests; takes ~3s
mix format --check-formatted
mix compile --warnings-as-errors      # dev env — test/support fixtures are deliberately noisy
mix dialyzer                          # PLT in priv/plts
mix docs                              # regenerates doc/
```

**The green gate is all four.** Not three. `mix test` passing means almost nothing on its own:

  * `mix dialyzer` is the *only* thing that catches the `contract_config/0` closed-map class
    (see below). A thousand passing tests will not.
  * `mix compile --warnings-as-errors` became meaningful in PR #103. Before that the codebase
    carried deliberate "unused require" compile-order anchors and the rule was to ignore them.
    Those are gone. A warning is now a real failure.
  * `mix docs` warnings matter and are easy to miss — read all of the output, not the tail. A
    backticked `Module.fun/arity` in `CHANGELOG.md` resolves as an ExDoc reference, and
    pointing at an internal `@doc false` function warns. Check with
    `mix docs --force 2>&1 | grep -ci warning`.

A pre-commit hook enforces `mix format --check-formatted`. It lives in `.git/hooks/pre-commit`,
is not version-controlled, and will not survive a fresh clone — re-create it if you land in one.

### Environment

`mix` needs the asdf shims on `PATH`:

```sh
export PATH="/Users/jvoegele/.asdf/shims:$PATH"
```

`.tool-versions` may name a toolchain that is not installed locally; use the nearest available.
**Do not try to reproduce version-specific behaviour locally across asdf installs** — it does
not work cheaply (mismatched OTP, colliding `MIX_HOME` hex archives, TLS failures installing
hex on older OTP). Write the behaviour as a test, push, and read the CI matrix. It spans 1.16
through 1.20 and answers for every version at once.

The library targets Elixir `~> 1.16`, so APIs added in 1.17+ are off-limits in `lib/`.

---

## Layout

| Path | What |
| --- | --- |
| `lib/bond.ex` | `use Bond`, the `@` override, `check/1`. Its `@moduledoc` is **read from README.md at compile time** — see Docs below. |
| `lib/bond/compiler/` | Everything that runs at compile time. This is where the sharp edges are. |
| `lib/bond/runtime/` | The small amount that runs per call. |
| `lib/bond/predicates.ex` | `~>`, `<~`, `xor`, `implies?`, `forall`/`exists`, and the Dialyzer-laundering helpers. |
| `test/support/bond_test/` | Fixtures that `use Bond`. Compiled in `:test` **alongside `lib/`** — the source of the compile race below. |
| `integration/consumer/` | A separate mix project depending on Bond by path. Proves generated code is warning-free and Dialyzer-clean in a real consumer, in both a normal and a `MIX_ENV=purged` build. |
| `bench/` | `compile_overhead.exs` (CI-guarded) and `runtime_check_overhead.exs`. |
| `guides/` | 17 guides, listed in `mix.exs` `extras:` in reading order, and shipped in the package `files:`. |
| `mikado/` | Mermaid graphs, one per substantive piece of work. See Workflow. |

### How compilation works, in one paragraph

`use Bond` overrides `Kernel.@/1` so `@pre`/`@post`/`@invariant`/`@doc` can be intercepted, and
installs `@on_definition`, `@before_compile` and `@after_compile` hooks. Intercepted contracts
are accumulated in a per-module `gen_statem` (`Bond.Compiler.CompileStateFSM`) keyed by module
name. At `@before_compile`, every contracted function is marked `defoverridable` and redefined
as one wrapper clause per user clause — each reproducing the original head and `when` guard, so
Elixir's dispatch survives — delegating to lifted assertion `defp`s. `@after_compile` stops the
FSM.

Two consequences that explain most of the traps: **contract checking happens in generated
functions Elixir's own diagnostics report by their generated names**, and **the whole thing runs
during someone else's macro expansion**, which is why scheduling matters.

---

## Traps

### 1. The parallel-compile race (`lib/bond/compiler/`)

**The single most expensive thing in this repo to get wrong.**

Mix schedules `lib` and `test/support` together (Bond's `elixirc_paths` includes both in
`:test`). Bond's FSM calls `AnnotatedFunction.new/1` at *user-module compile time* — when a
fixture does `use Bond` — not at the FSM's own compile time. Mix cannot see that dependency, so
nothing orders it.

The only guard is **`Code.ensure_compiled!/1` at three points**, forming a chain:

```
Bond.__using__/1           ensure_compiled!(Bond.Compiler)
  → Bond.Compiler.init/1   ensure_compiled!(CompileStateFSM)
    → CompileStateFSM.start_link/1
                           ensure_compiled!/1 over [Server, AnnotatedFunction,
                                                    AnnotatedFunction.Clause,
                                                    FunctionDefinition]
```

Each carries a `LOAD-BEARING` comment. **Do not remove one because "the alias is right there."**
Measured on Elixir 1.20 from a clean `_build/test`:

| Configuration | Clean builds | Passed |
| --- | --- | --- |
| Old `require` anchors alone, guards removed | 6 | **6** |
| `alias`es alone, no guard | 12 | **0** |
| Shipped: aliases + `ensure_compiled!` | 15 | **15** |

Without a guard this is not a rare race, it is deterministic.

> **The trap inside the trap.** `mix xref graph --label compile` reports **zero** compile-label
> edges for a scheduling `require`, and Elixir 1.20 warns `unused require X (convert it to an
> alias instead)`. Both look like proof the require is inert. Both are wrong — the negative
> control above shows those requires were imposing ordering. Never take either diagnostic as
> licence to convert a scheduling `require` to an `alias`. If you remove one, replace it with an
> explicit `Code.ensure_compiled!/1` and prove the swap with a negative control: strip the
> guard, expect failures; restore, expect passes.

Rules that follow:

  * Any module reached from a macro body on the `use Bond` expansion path needs an explicit
    `Code.ensure_compiled!/1`. Adding a link to that chain? Add a guard.
  * **Placement is everything.** It works from `start_link/1` / `__using__/1` — the *compiler*
    process, during expansion. It does **not** work from inside a spawned `gen_statem` worker,
    which is not compiler-owned and cannot participate in pending-module resolution.
  * **No nested `defmodule` blocks** in `lib/bond/compiler/*.ex`. Two BEAM files from one
    compilation unit have no ordering guarantee. `AnnotatedFunction.Clause` and
    `CompileStateFSM.Server` were extracted for exactly this reason.
  * File size is *not* a correctness concern any more. Several modules were originally split to
    win the race; the guards made that deterministic. Split for readability.
  * A **doc-only change** to an internal module has flipped this race before. If a CI-only
    failure follows a documentation change, suspect scheduling first — and if it happens now,
    a guard is missing.

Diagnostics: `ls _build/test/lib/bond/ebin/` (a missing BEAM is the victim);
`MIX_ENV=test mix compile --verbose 2>&1 | grep "Compiled"` (scheduling order);
`gh run view <id> --log | grep "Cache hit"` — a `Cache hit for restore-key:` line rather than an
exact key means a stale partial `_build` restore, which has caused this in CI twice.

### 2. `contract_config/0` is a closed map type

`Bond.Compiler.AnnotatedFunction.contract_config/0` is declared with `required(...)` /
`optional(...)`. The config map is threaded from `__before_compile__/1` into codegen and is the
natural place to carry anything the emitters need — but **adding a key without declaring it in
that type makes every call carrying the map fail to match**, and Dialyzer reports
`apply_contract` / `emits_preconditions?` as "will not succeed".

This has bitten three times (`:aliases` for #93; `:private_defs` +
`:warn_unavailable_preconditions` for #92; `:hidden_defs` for #110). The code was correct at
runtime every time, and the tests said nothing.

**When you put anything new on that map, declare it as `optional(...)` in the same edit, and run
`mix dialyzer` before pushing.** `:at_annotations` is the precedent for a non-contract-kind key
riding along; its comment says why that is acceptable.

### 3. A variable's identity is name **and** hygiene context

Root cause of #105. Source-parsed AST gives every variable context `nil`. A head built by a
macro with `unquote_splicing/1` carries the `quote`'s context (`Elixir`) — which is how
`Ecto.Schema` emits `__schema__/1,2` and Norm emits `__contract__/1`.

**The invariant to preserve: the wrapper head must bind each canonical name in `nil`.**

The obvious fix — rewrite the head variable's context to `nil` in place — passes the simple
cases and is wrong, because `ClauseWrapper` reproduces each clause's `when` guard on its own
head and that guard still refers to the variable in its *original* context. Hence
`canonical = <original pattern>`, binding both. The `doubled/1` fixture in
`BondTest.GeneratedHeads` exists to catch a regression to the in-place form.

> **Testing trap.** Compiler unit tests that build fixtures with `quote(do: [x])` stamp the
> *test module's* context on every variable — a shape no real clause head has. Use
> `BondTest.AST.as_source/1` to model source AST.

### 4. The purged-build blind spot

Bond's suite compiles in `:test`, where nothing is purged. **A defect that only appears in a
purging build is structurally invisible from inside the suite** — and a purging build is what
adopters ship to production and gate on `--warnings-as-errors`. #76 and #79 both came from this
gap.

Guarded since 1.14.0: the `downstream` CI job compiles `integration/consumer` a second time with
`MIX_ENV=purged` under `--warnings-as-errors`, against `ContractConsumer.PurgeShapes`.

Any change to what Bond *emits* should be reasoned about in both builds. When adding a fixture
there, check it actually fails against the pre-fix library — a guard that passes either way is
theatre.

### 5. `capture_io(:stderr)` is global; use `BondTest.Diagnostics`

`ExUnit.CaptureIO.capture_io(:stderr, …)` swaps the **global** stderr device, so it collects
whatever every concurrently-compiling test writes. In an `async: true` module,
`refute output =~ "unused"` fails whenever an unrelated fixture emits a warning at that moment.

That was #86, which reached CI three times with a *different* polluting module each time.

Use `BondTest.Diagnostics` (`test/support/bond_test/diagnostics.ex`), which wraps
`Code.with_diagnostics/1` and is process-local. `capture/1` returns diagnostics, `warnings/1`
their joined messages. The dangerous shape is specifically **`refute` + global capture +
`async: true`**; `assert output =~ …` and sync modules are safe.

### 6. The compile-overhead bound is not portable

`bench/compile_overhead.exs` takes `BOND_MAX_COMPILE_RATIO` and exits 1 past it; the
`compile_overhead` CI job runs it. The bound is **18.0**.

**Never reason about that number from a local run.** The same commit measures ~9–11x on the
GitHub runner and ~16.6x on an M3 Max, because the two halves do not scale together: Bond's
share is macro expansion in Elixir, the baseline's is BEAM compilation, and slower cores
penalise the latter more. Consecutive runs of the *same* commit on the runner reported 9.32x,
11.33x and 8.83x. If the bound ever needs moving, read the new figure from CI and leave generous
headroom over the highest observation.

### 7. The `try/rescue` per assertion is a decided trade, not a regression

Each emitted assertion is wrapped in `try/rescue` (#77) so an assertion that *raises* reports as
`Bond.AssertionEvaluationError` naming the contract, rather than a bare `FunctionClauseError`
from inside the predicate. It tripled per-module compile time (11 ms → 31 ms) and was filed as a
regression. Measuring the alternatives reversed that (#96):

| Variant | Compile | Runtime, `@pre` enabled |
| --- | --- | --- |
| Current (`try` per assertion) | 31 ms | **85 ns** |
| No `try` at all | 11 ms | 262 ns |
| `try` in the runtime behind a thunk | 11 ms | 299 ns |

The `try` makes the enabled path ~3x *faster*, probably by narrowing what `fn -> binding() end`
closes over. **Do not "optimise" it away without re-measuring both dimensions.**
`guides/overhead.md` states it as a trade.

### 8. Invariant head detection

`Bond.Compiler.Invariants.detect_struct_params/4` decides where an entry check is emitted. Three
bugs in it (#93, #84, #80) all failed the same way: silently skipping a check Bond documented as
running.

**Two resolvers, deliberately different.** Emission uses `same_module?/3`, resolving *exactly*
against the module's alias table (threaded from `env.aliases`). The `warn_skipped_invariants`
heuristic keeps a looser trailing-segment match. Emission cannot afford looseness: Elixir does
not auto-alias a module's own last segment, so inside `MyApp.Cart` the pattern `%Cart{}` names
`Elixir.Cart`, and binding `subject` to a foreign struct would evaluate the invariant against the
wrong value.

**Ordering trap in `ClauseWrapper`:** nested struct names must be collected from the *original*
params and added to the exclusion set, because `rewrite_clause_params/3` underscore-prefixes head
names the wrapper body does not reference and runs *before* detection.

### 9. Long-lived BEAMs and the per-module FSM

Editing a `use Bond` module in ElixirLS/IEx used to raise
`{:error, {:already_started, pid}}` on every edit: an aborted compile returns before
`__after_compile__` runs, leaving the per-module FSM registered.

`CompileStateFSM.start_link/1` now stops the leftover and starts fresh (its state is dead
anyway), with `stop/1` wrapped in `try/catch :exit` for the race where it dies first.

**Don't assume `__after_compile__` cleanup always runs.** Any compile-time process keyed on a
stable per-module name must tolerate a stale predecessor.

---

## Conventions

### Docs

`lib/bond.ex` builds its `@moduledoc` by reading `README.md` at compile time, between
`<!-- README START -->` and `<!-- README END -->`. **Edit the README, not the moduledoc.** The
README is simultaneously the GitHub front page, the HexDocs landing page, and the module doc.

`mix docs` **does not validate cross-file anchors** — it reports clean on a link to a heading
that does not exist. Anchors slugify in non-obvious ways (`don't` → `don-t`,
`Bond.PreconditionError` in a heading → `bond-preconditionerror`). Verify new anchors against the
generated HTML in `doc/`, not against a slug rule you believe. Note that ExDoc's module-autolink
syntax ``[text](`Bond.Config`)`` is not a file path and will false-positive in a naive checker.

Authoring `guides/cheatsheet.cheatmd`: cards are `###` under a `##` carrying `{: .col-2}` on the
line directly below. Two failure modes visible only in a browser — a `|` inside a table cell
(even in backticks) is parsed as a delimiter and silently collapses the remaining rows (escape as
`` `p \|\|\| q` ``; the `&#124;` entity renders literally inside backticks); and code spans in
narrow cells break at internal spaces, splitting tokens. Keep table code spans under ~30 chars,
prefer 2 columns, and verify by parsing `doc/cheatsheet.html` rather than by eye.

**Spell it "Design by Contract"** — capital D, lowercase "by", capital C, no hyphens. Abbreviated
"DbC". This was normalized across all docs and the `mix.exs` package description; don't
reintroduce variants.

The prose standard for guides: **demonstrate, don't argue.** Passages that defend the library
rather than show it working get cut. And every example and measurement gets run before it is
written down — the plausible-but-unchecked ones have been wrong repeatedly.

### The stability contract is more specific than "don't break the API"

Read both before any behaviour change:

  * **`guides/stability.md`** — covered surface includes "the `use Bond` macro and **the
    attribute syntax it intercepts**", the telemetry event, the error structs, and the `:bond`
    config keys. Behaviour changes are treated like removals: deprecated in a minor, changed in
    the next major.
  * **`guides/public-api.md`** — this is the surprise. It commits to *implementation-level*
    facts. It says in so many words that `xor/2`, `implies?/2` and `|||/2` are **`def`s**. That
    is why #127 (should `implies?/2` short-circuit?) is a major-version question rather than a
    small improvement.

When a behaviour change is right but policy says major, ask whether it can be made **loud**
instead — that is what happened with the `__*__` weaving skip: shipped in a minor, with a
compile-time warning naming the function, and `stability.md` amended in the same PR so policy and
behaviour agree. Amending the policy page silently is not the same thing.

Note what *is* allowed in a minor, so you don't over-ask: "new compile warnings may be added in
any minor release if they catch genuine footguns", provided they ship opt-out.

### Diagnostics

A warning that fires on correct code is worse than no warning — people suppress the category and
the true positives go with it. `Invariants.any_clause_mentions_struct?/2` states this in its own
moduledoc. #80, #110 and #111 are the same principle applied further. Invoke it explicitly when
scoping any new diagnostic.

Every warning ships with three opt-out scopes: `@bond_warn_x false` per function,
`use Bond, warn_x: false` per module, `config :bond, warn_x: false` globally.

`Bond.Compiler.Linter` (the assertion linter) is deliberately narrow — it fires only where it can
*prove* an assertion constant. Heuristic rules do not belong there; see issue #130 for where they
might go instead.

### Testing

`config/config.exs` sets `lint_assertions: false` in `:test`, because Bond's own fixtures use
degenerate assertions (`1 == 1`) as scaffolding. Tests that exercise the linter turn it back on
explicitly with `Application.put_env(:bond, :lint_assertions, true)`.

---

## Workflow

**Mikado method.** Substantive work is planned in a Mermaid graph at `mikado/<work-name>.mmd`,
committed as the first step. The graph lists numbered commit-sized steps, dependencies, and
leaves. Each subsequent commit is one step and leaves the suite green. Combine two steps only
when splitting would leave the system broken, and say so in the commit message.

**Branches.** `feature/<name>` for substantive work, opened with `gh pr create`, merged after
Jason reviews. Squash for a single-concern PR; `--no-ff` merge commit when the branch has 2+
coherent commits worth preserving. Ask if unsure — it is permanent `main` history. Small
docs-only changes go directly on `main`.

**Substantive work goes on a branch even mid-release.** A PR also gets it the full Elixir matrix,
which has mattered.

**Releases.** `release/X.Y.Z` from `main`, merged back `--no-ff`. Tags are bare `X.Y.Z` — **no
`v` prefix**. Every release step is fair game *except* `mix hex.publish`, which **Jason runs
himself**. Do not attempt it.

Install snippets drift; find them with
`git grep '~> 1\.<old-minor>' -- ':!integration' ':!CHANGELOG.md'` rather than trusting a
hardcoded list. Leave historical references like `"introduced in 0.17.x"` alone — they document
when behaviour was added, not a version pin.

**Git state goes stale between turns.** Jason publishes, hotfixes and retags out of band. Before
committing on `main` or assuming release state, re-check `git status -sb`,
`git log --oneline -3` and `git tag --sort=-creatordate | head`.

Two process gotchas that cost real time:

  * **Retarget a stacked PR before merging its parent.** Merging with `--delete-branch`
    auto-closes any PR based on that branch, and GitHub then refuses to reopen it. Run
    `gh pr edit <child> --base main` first.
  * **`git reset --hard` is denied by the repo's permission guardrails.** To move a branch
    pointer, `git branch <name>` to save the work, then `git branch -f main HEAD~1`.

---

## Two standing habits

**Verify before writing.** Run every example, measure every measurement. Claims that were
plausible and unchecked have been wrong repeatedly — including several in dogfooding reports that
were then built on. A dogfood issue report is a starting point, not a specification: five of seven
in the last sweep had a claim that did not survive checking, and twice it changed the design
rather than the wording.

**Build a feature's motivating examples with what already ships, before scoping it.** That killed
#63 after its design was already settled.
