# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Quantified assertions: `forall` / `exists` with element-level failure diagnostics**
  ([#32](https://github.com/jvoegele/bond/issues/32)). Two new macros in `Bond.Predicates`
  (auto-imported into every assertion) express universal and existential quantification with
  comprehension-style generator syntax:

  ```elixir
  @pre all_positive: forall(x <- items, x > 0)
  @pre has_admin: exists(u <- users, u.role == :admin)
  @post sorted: forall(i <- 0..(length(result) - 2)//1,
                       Enum.at(result, i) <= Enum.at(result, i + 1))
  ```

  Unlike `Enum.all?/2` / `Enum.any?/2`, a failure reports **which** element violated the
  predicate and its index, rather than only that the whole expression was false:

  ```
  |   assertion: forall(x <- items, x > 0)
  |   counterexample: element at index 3 (-2) does not satisfy `x > 0`
  ```

  Both short-circuit (at the first violation / first witness), return ordinary booleans so
  they compose with `and` / `or` / `not` / `~>`, and work in `@pre`, `@post` (including over
  `result`), `@invariant`, and `Bond.check/1`. The element detail also rides along in the
  `[:bond, :assertion, :failure]` telemetry metadata under `:quantifier`. See the
  [Quantified assertions](guides/getting-started.md#quantified-assertions) guide for the
  documented limitations (nested quantifiers report the outermost element; a single
  generator per quantifier).

### Fixed

- **Documentation: corrected stale runtime-toggle guidance.** The FAQ, getting-started
  guide, and overhead guide still described the pre-1.1.0 contract gate
  (`Application.get_env/3` / `Application.put_env/3` per call). Since 1.1.0 the gate
  reads a single `:persistent_term` entry and the runtime on/off API is `Bond.Config`
  (`enable/1`, `disable/1`, `put/2`, `reset/0`); `Application.put_env/3` is no longer a
  live toggle once the modes term has been seeded. Docs now point at `Bond.Config` and
  describe the `:persistent_term` gate.

## [1.3.0] - 2026-06-15

Stable release of **Eiffel-style contract refinement** (`@pre_weaken` /
`@post_strengthen`), promoted from `1.3.0-rc.1` after dogfooding in a downstream
application. No functional changes since the release candidate; the refinement
syntax for both behaviour and protocol implementations is now covered by Bond's
[stability guarantees](guides/stability.md). See the `1.3.0-rc.1` notes below for
the full feature description.

## [1.3.0-rc.1] - 2026-06-15

Release candidate for 1.3.0. This release adds **Eiffel-style contract
refinement** (`@pre_weaken` / `@post_strengthen`) for both behaviour and protocol
implementations — the largest addition to Bond's contract-inheritance model since
it was introduced in 1.2.0, and entirely additive (no breaking changes).

It is published as a release candidate so the new refinement syntax can get
real-world exposure before it is frozen under Bond's
[stability guarantees](guides/stability.md). The surface is complete and tested;
feedback on the keywords and semantics is welcome via
[GitHub issues](https://github.com/jvoegele/bond/issues). To try it:
`{:bond, "~> 1.3.0-rc.1"}`.

### Added

- **Eiffel-style contract refinement of inherited behaviour contracts (GitHub
  #16).** An implementation that inherits a `Bond.Behaviour` callback's contract
  may now *refine* it instead of inheriting it verbatim, following Eiffel's
  behavioural-subtyping rules:

    - `@pre_weaken` **weakens** the inherited precondition — effective precondition
      is `inherited or pre_weaken` (contravariance; the impl accepts everything the
      abstraction promised, and more).
    - `@post_strengthen` **strengthens** the inherited postcondition — effective
      postcondition is `inherited and post_strengthen` (covariance; callers get at
      least the abstract guarantee, and more). It may also add a postcondition
      where the callback declared none.

  The distinct keywords make the (counterintuitive) variance explicit, and
  refinement expressions reference the **abstraction's canonical argument names**
  (those declared on the behaviour callback), not the implementation's own
  parameter names. Plain `@pre`/`@post` on an inherited operation remains a compile
  error. `@pre_weaken` requires an inherited precondition to weaken; `old/1` is not
  available in `@post_strengthen`. Qualified `Bond.pre_weaken/1` and
  `Bond.post_strengthen/1` are available for the `at_annotations: false` path.

- **Protocol contract refinement via `Bond.Protocol.Impl` (GitHub #16, Phase B).**
  A `defimpl` block may now opt in with `use Bond.Protocol.Impl` and use
  `@pre_weaken`/`@post_strengthen` to refine the protocol's contracts. The same
  Eiffel behavioural-subtyping rules apply (OR for pre, AND for post), enforced at
  the dispatch boundary. As with behaviour refinement, refinement expressions
  reference the **abstraction's canonical argument names** (declared in the
  protocol's own `def`). Plain `defimpl` blocks that do not opt in are completely
  unaffected.

## [1.2.1] - 2026-06-12

### Fixed

- **Pattern-bound names are now allowed in protocol and behaviour contracts.** A
  contract that binds a name inside a `<~` match pattern — e.g.
  `@post ({:ok, path} when is_binary(path)) <~ result` — was incorrectly rejected
  at compile time, with the reference validator treating the pattern-local `path`
  as a reference to an undeclared argument. Such names are bound by the match (not
  references to function arguments) and are now exempt from the validation. A
  `when` guard on the pattern may still reference an outer name, and those
  references continue to be validated (surfaced while dogfooding contract
  inheritance).

## [1.2.0] - 2026-06-11

Brings **contract inheritance** to Bond: a behaviour or a protocol declares
`@pre`/`@post` once, and every implementation enforces them — Design by Contract
meeting the Liskov Substitution Principle. The release is backwards compatible;
all additions are opt-in, and the new modules and options are now covered by the
stability guarantees in `guides/stability.md`.

### Added

- **Contract inheritance for behaviours (GitHub #13).** A behaviour can declare
  `@pre`/`@post` contracts on its `@callback`s with the new `Bond.Behaviour`,
  and any module that inherits them with `use Bond, behaviours: [TheBehaviour]`
  enforces those contracts on its own clauses — Design by Contract meeting the
  Liskov Substitution Principle.

    - Contracts reference the callback's argument names and bind by position,
      so an implementation may name its parameters freely; the rebind applies
      uniformly across every clause of a multi-clause implementation.
    - `use Bond, behaviours: […]` emits `@behaviour` for each module, so
      `@impl` and Elixir's callback checks apply without a separate declaration.
    - Violations are attributed to their origin: the message reads
      `precondition (inherited from Ledger) failed for call to
      BankAccount.withdraw/2`, and a `:source_behaviour` field is added to the
      precondition/postcondition error structs and to the
      `[:bond, :assertion, :failure]` telemetry metadata.
    - Inheritance is **immutable** in v1: an implementation may not modify or
      add to an inherited contract. Attaching `@pre`/`@post` to an inherited
      operation is a compile error (use `check/1` for implementation-specific
      assertions); two behaviours constraining the same operation must be
      structurally identical; and a non-`Bond.Behaviour` module passed to
      `behaviours:` is a compile error.
    - A callback contract may reference only the callback's named arguments
      (and `result` in a `@post`). Referencing any other name — a typo, or an
      unnamed callback position — is a compile error reported against the
      behaviour where the contract is declared, rather than surfacing as an
      opaque error in each implementing module.

  See the [Contract Inheritance](guides/contract-inheritance.md#behaviours)
  guide.

- **Contract inheritance for protocols (GitHub #15).** A `defprotocol` can
  declare `@pre`/`@post` contracts on its functions with the new `Bond.Protocol`,
  and every implementation — present or future — enforces them at dispatch.

    - Implementations need zero Bond awareness: a `defimpl` stays completely
      ordinary, with no `use Bond` and no opt-in.
    - Bond wraps the protocol's generated dispatch function once
      (`defoverridable` + `super`), so the contract applies uniformly to all
      implementations and **survives protocol consolidation**. Contracts
      reference the function's declared argument names (and `result` in a
      `@post`); no positional rebind is needed.
    - Violations are attributed to the protocol and name the resolved
      implementation: the message reads `postcondition (from protocol Sized,
      impl Sized.List) failed in Sized.size/1`, and `:source_protocol` and
      `:impl` fields are added to the error structs and the
      `[:bond, :assertion, :failure]` telemetry metadata (the implementation is
      resolved only on the failure path).
    - Inheritance is **immutable** in v1: implementations cannot refine a
      protocol's contracts. Only calls through the protocol are checked (a direct
      call to a concrete implementation bypasses dispatch); `old/1` in a protocol
      `@post` and compile-time `:purge` of protocol contracts are not supported.

  See the [Contract Inheritance](guides/contract-inheritance.md#protocols)
  guide.

## [1.1.0] - 2026-06-05

Adds a supported runtime-configuration API (`Bond.Config`), makes the per-call
runtime gate substantially cheaper, brings the ECMA-367 exit order in line with
the standard, and adds Elixir 1.20 / OTP 29 to the test matrix.

The public-API additions are backwards compatible. Two behavioural changes are
called out under **Changed** below — both have a clear migration and neither
affects compile-time configuration (`config.exs` / `config/runtime.exs`),
per-module `:overrides`, or `:purge`.

### Added

- **`Bond.Config` — runtime contract configuration.** A small public module for
  turning contract kinds on and off at runtime, replacing the previous reliance
  on `Application.put_env/3`:

    - `Bond.Config.enable/1` / `disable/1` / `put/2` — toggle a kind
      (`:preconditions`, `:postconditions`, `:invariants`, `:checks`).
    - `Bond.Config.enabled?/1` / `all/0` — inspect the current runtime state.
    - `Bond.Config.reset/0` — discard runtime overrides and re-seed from current
      application env.
    - `Bond.Config.kinds/0` — the list of configurable kinds.

  These take effect immediately and globally, and compose with the contract
  chain (`preconditions ≤ postconditions ≤ invariants`).

- **Elixir 1.20 / OTP 29 support.** Added a `1.20.0 / OTP 29.0.1` leg to CI; the
  full suite passes on Elixir 1.16 through 1.20.

### Changed

- **The runtime contract gate is now backed by `:persistent_term`.** Whether a
  contract kind is evaluated is resolved from a single lock-free
  `:persistent_term` read per call instead of a per-call `Application.get_env/3`.
  The term is lazily seeded from application env on the first contracted call, so
  `config.exs` and `config/runtime.exs` are honoured exactly as before. On a
  fully-contracted call the gate is roughly **2.6× cheaper**.

- **Behaviour change — runtime toggling via `Application.put_env/3` is no longer
  live.** Because the runtime modes are cached in `:persistent_term` after the
  first contracted call, calling `Application.put_env(:bond, <kind>, …)` at
  runtime no longer changes contract evaluation. Use **`Bond.Config`** to toggle
  contracts at runtime, or **`Bond.Config.reset/0`** to re-seed from current
  application env. Setting `config :bond, …` in `config.exs` /
  `config/runtime.exs` before the application starts is unaffected.

- **Behaviour change — on exit, the class invariant is now evaluated before the
  postcondition** (matching ECMA-367 §8.23.26 and the entry order, where the
  pre-invariant precedes the precondition). When a function's postcondition *and*
  its struct invariant both fail on return, the raised error is now
  `Bond.InvariantError` rather than `Bond.PostconditionError`. Correctness is
  unchanged — the two checks are conjoined and order does not affect whether a
  violation is detected — only which violation surfaces first.

- **The failure binding is captured lazily.** The local binding reported in
  contract-failure errors is now snapshotted only when an assertion actually
  fails, rather than on every successful evaluation. Error contents are
  unchanged; the per-call cost of an *enabled* contract no longer grows with the
  function's arity or its number of `old(...)` captures.

- **Dialyzer laundering moved off the call boundary.** The generated lifted
  assertion functions now carry `@dialyzer {:nowarn_function, …}` instead of
  routing their arguments through the internal `__opaque__/1` helper in
  `Bond.Predicates` at the call site. This keeps downstream `mix dialyzer` clean
  for contracts that duplicate a typespec-implied fact, at zero runtime cost. The
  `~>` / `<~` operator launderers are unchanged.

## [1.0.0] - 2026-06-02

First stable release. 1.0.0 promotes 1.0.0-rc.4 unchanged; the Semantic
Versioning guarantees in `guides/stability.md` are now in force over the
enumerated public API surface.

The release-candidate cycle delivered:

- **rc.1** — documented and frozen public API; the semver stability promise;
  published compile-time and runtime overhead numbers; Elixir 1.16–1.19 CI.
- **rc.2** — library coexistence (`use Bond, at_annotations: false`,
  tolerance of externally-generated override clauses); keyword-only contract
  labelling.
- **rc.3** — split the overloaded `contract_holds/2` into `contract_holds/2`
  (single-function form) and `invariants_hold/2` (stateful module-sequence
  form).
- **rc.4** — multi-clause `@invariant` soundness fix (GitHub #22).

See the entries below for the detailed changes made in each candidate.

### Known issues

- **GitHub #23** — Elixir 1.18+'s set-theoretic type checker may flag a head
  destructure on some Bond-wrapped multi-clause functions. This is diagnostic
  noise only; the contracts and the wrapped functions behave correctly. It
  could not be reproduced from reconstructed shapes and may already be resolved
  by the rc.4 guard-preservation fix; it remains open under investigation.

## [1.0.0-rc.4] - 2026-06-01

Fixes a soundness gap in multi-clause `@invariant` enforcement (GitHub #22).

### Fixed

- **A struct clause's `@invariant` pre-check is no longer silently skipped on
  heterogeneous multi-clause functions.** When a function had a clause binding a
  `%__MODULE__{}` struct alongside a sibling clause binding a non-struct value,
  two bugs combined to skip the struct clause's pre-invariant:

    1. The canonical-name rewrite wraps such a struct head as a nested match
       (`bond_arg_0 = (%__MODULE__{} = ctx)`), which the struct detector didn't
       recognise.
    2. Per-clause wrappers dropped the user clause's `when` guards, so a guarded
       bare-variable clause became a catch-all that shadowed a following struct
       clause — `super` re-dispatched to the correct clause (so results were
       right) but the pre-invariant never fired.

  Both are fixed: struct detection sees through the nested match, and wrapper
  clauses now reproduce the user's guards.

### Changed

- **A contracted multi-clause function called with an argument that matches no
  clause now raises `FunctionClauseError`** (as an uncontracted function would),
  rather than a precondition violation. The previous behaviour — a precondition
  firing for an input that entered no clause — was a side effect of the
  guard-dropping bug above. Preconditions apply per matched clause.

## [1.0.0-rc.3] - 2026-06-01

Splits the overloaded `Bond.PropertyTest.contract_holds/2` macro into two
clearly-named macros so the testing shape is named at the call site rather than
inferred from the first argument's form.

### Added

- **`Bond.PropertyTest.invariants_hold/2`** — the stateful, sequence-based
  property-testing macro. It runs random sequences of constructor / transformer
  / observer operations over a struct module and uses the module's
  `@invariant`s (plus any per-function `@pre`/`@post`/`check` contracts) as the
  oracle across every reachable state. This is the form that previously lived
  under `contract_holds Module, ...`. The name echoes the `@invariant`
  annotation that is the form's whole point. `contract_holds/2` and
  `invariants_hold/2` now cross-link each other in their docs.

### Breaking changes

- **`contract_holds/2` no longer accepts a module.** The stateful
  module-sequence form moved to `invariants_hold/2`; `contract_holds/2` is now
  exclusively the single-function form (`contract_holds &Mod.fun/n, args:
  [...]`). Passing a module alias to `contract_holds/2` raises a `CompileError`
  with a migration message rather than dispatching silently.

      # Was:
      contract_holds BoundedStack, constructors: [...], transformers: [...]

      # Now:
      invariants_hold BoundedStack, constructors: [...], transformers: [...]

  The module form shipped only in `1.0.0-rc.2`, so there is no deprecation shim.

## [1.0.0-rc.2] - 2026-06-01

Lets Bond coexist, in a single module, with other libraries that override
`Kernel.@/1` or wrap functions, and finishes unifying contract labelling on the
single keyword-list form.

### Added

- **`use Bond, at_annotations: false`** — an opt-out of Bond's `Kernel.@/1`
  override for a module. The `@pre`/`@post`/`@invariant` forms are then
  unavailable; write contracts as the fully-qualified `Bond.pre/1`,
  `Bond.post/1`, and `Bond.invariant/1` calls instead (`check/1` stays
  unqualified). This lets Bond share a module with another library that owns
  `@` — e.g. Norm's `@contract`. The bare `pre`/`post`/`invariant` macros are
  never imported in either mode, so they cannot collide with user function
  names. See the FAQ entry "Can I use Bond and Norm in the same module?"

- **Tolerance of externally-generated override clauses.** Libraries that wrap a
  function via `defoverridable` + redefinition (Norm's `@contract`, the
  `decorator` library, etc.) inject a clause that Bond's `@on_definition`
  observes; Bond previously rejected the function as defined twice. Bond now
  detects and ignores those generated clauses and still wraps the function as a
  whole, composing with the other library's wrapper via `super`.

### Breaking changes

- **The positional `@pre` / `@post` label forms were removed.** `@pre <label>,
  <expr>` and `@pre <expr>, <label>` (and the same for `@post`) are gone — they
  were redundant with the keyword-list form, which already carries a label. This
  completes the single-labelling-syntax decision made for `check/2` in 0.16.0.

      # Was:
      @pre :positive, x > 0
      @post result >= 0, "non-negative result"

      # Now (labels are atoms; quote the key for spaces or punctuation):
      @pre positive: x > 0
      @post "non-negative result": result >= 0

  `@pre expr` (bare) and `@pre label: expr` (keyword) are the two remaining
  forms. The removed positional shapes raise a `CompileError` with the migration
  message. The qualified `Bond.pre`/`Bond.post` calls are likewise keyword-only.

### Fixed

- **`(MatchError) … {:error, {:already_started, #PID<…>}}` when editing a `use
  Bond` module under ElixirLS or in a long-lived IEx session.** A compile that
  aborted (e.g. a transient syntax error mid-edit) left Bond's per-module
  compile-state process registered, so the next compile crashed trying to start
  it again. Bond now discards the stale process and starts fresh. One-shot `mix
  compile` was never affected; the bug surfaced only in editors and IEx that
  keep the BEAM alive across recompiles.

## [1.0.0-rc.1] - 2026-05-28

First **release candidate** for Bond 1.0.0. Published to gather
feedback from the Elixir community before the stability guarantees in
`guides/stability.md` lock in at 1.0.0 final. Bug reports and design
feedback are welcome at https://github.com/jvoegele/bond/issues — small
adjustments to the public surface are still possible between RC and
final, based on what we hear.

### 1.0 highlights

- **Documented and frozen public API surface.** See
  [Public API surface](guides/public-api.md) for the exhaustive
  enumeration of every name covered by the semver contract — module
  attributes, macros, operators, the `Bond.Predicates` callables,
  `Bond.Test` and `Bond.PropertyTest` helpers, the telemetry event
  and metadata shape, the four error structs, the configuration keys,
  and the public type set. Internal namespaces (`Bond.Compiler.*`,
  `Bond.Runtime.*`) are explicitly carved out.
- **A semver-style stability promise.** See
  [Stability guarantees](guides/stability.md) for what patch / minor /
  major mean in practice, what's explicitly excluded (compile-error
  message text, generated-code shape, `Exception.message/1` output),
  and the deprecation policy (minimum one minor with a deprecation
  warning before removal in next major).
- **Published overhead numbers.** See
  [Overhead](guides/overhead.md) for concrete compile-time and runtime
  cost figures from a documented reference environment, with
  `mix run bench/...` recipes for re-running on your hardware.
  Headlines: a `:purge`d contract is free; an enabled `@pre` adds ~130
  ns/call; Bond compile-time overhead is ~10 ms per module that uses
  contracts.
- **Compatibility verified across Elixir 1.16–1.19 in CI** — the
  declared `~> 1.16` floor, with parallel-compile races fixed and a
  Dialyzer baseline established for Bond's own library code.
- **Known footguns either fixed, documented, or surfaced as
  compile-time warnings.** New `:warn_skipped_invariants` opt-out
  warning catches the most common silent-skip case (see Migration
  below).

### Migrating from 0.18.x

**No breaking API changes.** Code written against 0.18.x continues to
compile and run identically. There is, however, one new opt-out
compile warning that may surface in code that previously compiled
without diagnostics — described next.

**`:warn_skipped_invariants` is the only new behaviour you may see.**
Bond now emits a compile-time warning when a public function in an
invariant-declaring module has neither a head that pattern-matches the
struct nor a body that returns one — those functions silently skip
invariants entirely (the footgun the warning was designed to catch).
If your codebase has struct modules with utility or constructor
functions whose bodies don't return literal `%__MODULE__{...}` or
`{:ok, %__MODULE__{...}}`, you may see warnings of the form:

```
public function `MyMod.helper/0` in invariant-declaring module
`MyMod` has no clause that pattern-matches the struct or returns
one; invariants are skipped here. If intentional, suppress with
`@bond_warn_skipped_invariants false` (per function), `use Bond,
warn_skipped_invariants: false` (per module), or `config :bond,
warn_skipped_invariants: false` (globally).
```

The detection is conservative on the post-side: only literal struct
returns suppress the warning automatically. Helpers like
`def from_map(m), do: build(m)` still warn; the per-function attribute
is the workaround.

Three suppression knobs ship; pick the narrowest scope that fits the
intent:

- **Per function** (recommended for individual utility/constructor
  functions): `@bond_warn_skipped_invariants false` placed before the
  `def`. Tri-state — `true` re-enables under a module/global `false`.
- **Per module** (for modules whose whole purpose isn't the struct —
  rare; reconsider whether `@invariant` belongs there at all):
  `use Bond, warn_skipped_invariants: false`.
- **Global** (use sparingly — you lose the footgun-catcher
  everywhere): `config :bond, warn_skipped_invariants: false`.

See the FAQ entry "Why is Bond warning about skipped invariants?" for
the full diagnostic guide.

### Documentation

- **Closed #8 — `old/1` docs lead with a non-racy example.** The
  README's `old expressions` section and the getting-started guide
  both previously led with a stateful `Agent` example that has an
  acknowledged race (another process can interleave between the `old`
  snapshot and the postcondition evaluation). New users would copy the
  racy pattern as their starting point. Replaced with a process-
  dictionary turn counter — stateful (so `old` has a meaningful
  purpose; for an immutable parameter `old(x)` and `x` are the same
  value) but local to a single process (so the snapshot and the
  post-check observe the same world). The concurrency caveat is
  retained as a callout with a link to the concurrency guide; the
  Agent example stays in the concurrency guide proper, where it's the
  case study for the locking workaround.

- **Closed #9 and #20 — overhead benchmarked and published.** New
  `guides/overhead.md` publishes concrete compile-time and runtime
  overhead numbers from a documented reference environment (Apple M3
  Max, OTP 27.2, Elixir 1.19.5). Two benchmark files under `bench/`
  back the numbers and are documented as the "re-run on your hardware"
  recipe.
  - **Compile-time** (`bench/compile_overhead.exs`): ~10 ms/module
    overhead for modules using Bond + a handful of contracts. For a
    200-module application, that's ~2 s added to a clean
    `mix compile`. Bond starts a `:gen_statem` per compiling module
    (stopped in `__after_compile__`); the per-module cost is roughly
    constant in the number of modules. Closes #9.
  - **Runtime** (`bench/runtime_check_overhead.exs`, expanded from
    the previous `@pre`-only-with-three-modes version): full grid of
    `(baseline, @pre, @post, @invariant, check/1)` ×
    `(true, false, :purge)`. Headline numbers: enabled `@pre` adds
    ~130 ns/call; runtime-disabled `@pre` (`false`) adds ~70 ns;
    `:purge` is indistinguishable from baseline. `@invariant` is the
    most expensive at ~440 ns/call (entry + exit checks). Closes #20.
  - FAQ entry "Will contracts slow down my production code?" gains a
    closing paragraph linking the new guide and surfacing the headline
    figures.

- **Closed #1 — public API surface frozen and documented for 1.0.**
  Two new guides published to hexdocs:
  - `guides/public-api.md` enumerates every name covered by the 1.0
    semver contract: attribute syntax (`@pre` / `@post` / `@invariant`
    / `@doc` and accepted argument shapes), macros and operators in
    `use Bond` scope, `use Bond` options, the
    `@bond_warn_skipped_invariants` per-function attribute, the
    public `Bond.Predicates` callables (with `__opaque__/1` and
    `__truthy__/1` explicitly called out as infrastructure-only),
    `Bond.Test` and `Bond.PropertyTest` helpers, the
    `[:bond, :assertion, :failure]` telemetry event and its metadata
    shape, the four error structs and their field layout, application
    config keys, and the public type set.
  - `guides/stability.md` states the semver promise (what patch /
    minor / major mean), the explicit exclusions (internal modules,
    generated-code shape, compile-error message text,
    `Exception.message/1` rendering), and the deprecation policy
    (minimum one minor with a deprecation warning before removal in
    next major).
  The main Bond moduledoc (README between the START/END markers)
  gains a short "Stability and the public API surface" section
  pointing to both guides.

- **`mix docs` warning-free for the first time.** Three pre-existing
  cross-link warnings adjudicated as part of the surface audit:
  `Bond.Compiler.CompileStateFSM.Server` switched from `@moduledoc
  false` to `@moduledoc internal: true` (consistent with the rest of
  `Bond.Compiler.*`); two CHANGELOG references to internal helpers
  rephrased to drop the `Mod.fun/arity` cross-link pattern without
  losing the technical detail. No public surface change.

### Added

- **Closed #5 — opt-out compile warning for silently-skipped
  invariants.** A public function in an invariant-declaring module
  whose head doesn't pattern-match the struct AND whose body doesn't
  return one (statically detectable: `%__MODULE__{...}` or `{:ok,
  %__MODULE__{...}}`, including as the last expression of a block) has
  both its on-entry pre-check AND its on-exit post-check silently
  skipped — documented as a footgun in the README and FAQ, but
  uncatchable without reading every diff. Bond now emits a compile-
  time warning at the function's definition site naming the offender
  and offering all three suppression knobs.

  Detection is intentionally conservative on the post side: only
  literal struct returns suppress the warning. Functions that build
  the struct via a helper call (e.g. `def from_map(m), do: build(m)`)
  still warn; the per-function attribute is the workaround.

- **New `:warn_skipped_invariants` knob, three layers** (all public
  API as of 1.0; default `true` at every layer):
  - **Global:** `config :bond, warn_skipped_invariants: false`.
  - **Per-module:** `use Bond, warn_skipped_invariants: false`.
  - **Per-function:** `@bond_warn_skipped_invariants false` before
    the next `def`. Tri-state — omitting the attribute inherits the
    module/global setting; `false` suppresses for that one def;
    `true` re-enables the warning even under a module/global `false`
    (useful for selectively opting back in to verify a specific
    function under a project-wide suppression).

  Per-function is the right answer most of the time: a struct module
  with a few utility or constructor functions can suppress just those
  while leaving the safety net intact for everything else. Module-
  level suppression silences future regressions in the same module,
  so reach for it only when the entire module legitimately isn't
  about the struct (rare; reconsider whether `@invariant` belongs
  there at all).

### Changed

- **Closed #6 — per-contract disable mechanism scoped out of 1.0
  (FAQ rewrite).** The FAQ entry "How do I disable a single failing
  contract while debugging?" no longer punts on the design question.
  The three existing workarounds (comment out, move to `check/1`,
  disable the kind globally for the env) are presented as the
  supported answer with a one-line "when this is the right choice"
  hint each. Per-contract on/off knobs intentionally don't ship: Bond
  already has rich per-kind / per-module / per-`use Bond` toggles, and
  per-assertion off-switches tend to mask broken agreements rather
  than resolve them.

- **Closed #7 — three deferred features reframed as 1.0 scope
  boundaries.** Each restated as a deliberate scope decision with a
  workaround, replacing "not yet" / "may be added" / "if there is ever
  a demonstrated need" framing:
  - Contracts on macros (`lib/bond/compiler/compiler.ex:188` internal
    comment) — wrap the macro body in a contracts-annotated regular
    function and call that from the macro.
  - Per-clause contracts (`guides/faq.md`) — by-design at 1.0; if
    different clauses genuinely have different contracts, they're
    really two different functions. Bodyless-head + per-clause
    implementation is the workaround when parameter names differ.
  - Data-specification facility / `Bond.Spec` (`guides/history.md`) —
    won't ship. Data specification is Norm's job, contract programming
    is Bond's. Compose them via remote calls (see the FAQ).

### Internal

- **Closed #4 — `Kernel.@/1` override compatibility verified.** Adds
  test coverage that Bond's `@/1` catch-all forwards seven categories
  of standard Elixir attributes intact (`@derive`, `@enforce_keys`,
  `@spec`/`@type`/`@typep`/`@opaque`, `@callback`/`@behaviour`/`@impl`,
  accumulating custom attributes, `@external_resource`), and adds
  cross-library tests using Norm as the real-world counterpart (the
  only popular Elixir library that uses the same `import Kernel,
  except: [@: 1]` + specific clause + catch-all forwarding technique
  Bond does). Empirical finding: combining `use Bond` with another
  `@/1`-overriding library in a single module fails to compile with a
  clear `function @/1 imported from both ..., call is ambiguous` error,
  regardless of `use` ordering. The conflict is loud, not silent —
  contracts are never dropped without a diagnostic. 24 new tests
  (18 forwarding + 6 cross-library).

- FAQ entry "Can I use Bond and Norm in the same module?" documents
  the conflict, the exact error message, and two workarounds
  (split-modules pattern + using Norm's spec helpers as plain remote
  calls without `use Norm`). The existing "How does Bond compare to
  Norm?" entry is updated to cross-reference the new section instead
  of glossing over the per-module conflict.

- `norm ~> 0.13` added as a `:test`-only dependency (no transitive
  runtime cost — Norm has only optional `stream_data`, which Bond
  already declares).

### Requirements

- Unchanged. Elixir `~> 1.16`.

## [0.18.0] - 2026-05-28

Raises the Elixir version floor to 1.16 and aligns optional dependencies
with their current stable series. No changes to Bond's public API or
runtime behaviour.

### Changed (breaking)

- **Minimum Elixir version is now `~> 1.16`** (was `~> 1.14`). Elixir
  1.14 and 1.15 are no longer supported. The floor was raised to resolve
  formatter drift (the `(-> t)` zero-arity typespec syntax introduced in
  1.15.0) and to allow CI to run format-checking against the newest Elixir
  without a version pin.

- **`Bond.PropertyTest` requires `stream_data ~> 1.0`** (was `~> 0.6`).
  The optional property-based testing integration now targets the stable
  1.x release series. Users of `Bond.PropertyTest` must upgrade their own
  `stream_data` dependency to `~> 1.0` (current release: 1.3.0).

### Internal

- CI matrix now spans Elixir 1.16–1.19 / OTP 26–27; the 1.14 row is
  removed.
- `lint` job runs on Elixir 1.19.5 (was pinned to 1.14.5 due to formatter
  drift; pin is no longer needed).
- New `dialyzer` CI job runs `mix dialyzer` against Bond's own library
  code on Elixir 1.19.5 / OTP 27.2, establishing a clean Dialyzer
  baseline for the library itself (previously only the downstream consumer
  was Dialyzer-checked).
- GitHub Actions updated to Node.js 24 runtime (`checkout@v6`,
  `cache@v5`).
- `credo` updated 1.7.3 → 1.7.18; `stream_data` updated 0.6.0 → 1.3.0.

## [0.17.5] - 2026-05-28

A patch release eliminating downstream `mix dialyzer` warnings emitted by
Bond-generated code when the user's assertion duplicates a typespec-implied
guard. Surfaced by a dogfood round in a real consumer (Photon) where every
`use Bond` module produced one `pattern_match` or `pattern_match_cov`
warning, forcing the consumer to suppress with `@dialyzer :no_match` per
module.

### Fixed

- **Lifted assertion defps no longer emit `if`/`else` inline.** The
  truthiness check and throw-on-failure moved into two new
  `Bond.Runtime.Eval` functions — `check_assertion/3` (used by `@pre`,
  `@post`, and `@invariant`) and `check_value/3` (used by `Bond.check/1`).
  Each is defined as a multi-clause function matching `false`/`nil`/`_`,
  which prevents Dialyzer's caller-flow narrowing from killing the falsy
  clause when the user's expression is statically `true` (e.g. `@pre
  is_binary(x)` on a function `@spec`-narrowed to `binary()`).

- **Lifted-defp arguments are routed through a type-laundering helper.**
  `__opaque__/1` (and `__truthy__/1` for the `~>` operator), both in
  `Bond.Predicates`, use `:persistent_term.get/2` to defeat Dialyzer's
  parameter-type
  propagation from the wrapper into the lifted defp. Without this, an
  assertion expression containing `and`/`or`/`case` (which expand to their
  own internal `case`) would still narrow under the wrapper's `@spec`,
  producing `pattern_match` warnings inside the user's expression itself —
  e.g. `@post is_binary(result) and result != ""` on a function returning
  `binary()` had a dead `false ->` clause in the `and/2` expansion.

- **`Bond.Predicates.<~/2` discriminator is laundered.** The pattern-match
  operator's `case expr do pattern -> true; _unmatched -> false end`
  previously produced `pattern_match_cov` warnings when the user's pattern
  exhausted the `@spec`-narrowed type of `expr` (e.g. `{:ok, _} <~ result`
  on a function returning `{:ok, integer()}`). Routing `expr` through
  `__opaque__/1` keeps the `_unmatched` clause reachable.

- **`Bond.Predicates.~>/2` antecedent is laundered.** The implication
  operator's `if antecedent do !!consequent else true end` previously
  produced a `pattern_match` warning on the `else: true` branch when the
  antecedent was statically `true` (e.g. `is_binary(x) ~> ...` on a binary
  argument). Routing the antecedent through `__truthy__/1` keeps the
  `else` branch reachable.

### Internal

- **Five new fixtures** in `integration/consumer/lib/contract_consumer.ex`
  (`TypedGuard` and `TypedInvariant`) exercise every shape that previously
  warned: tautological `@pre` / `@post` / `@invariant`, `~>` antecedent
  tautology, `<~` exhaustive pattern. The existing downstream-Dialyzer CI
  job (added in 0.17.4) is now also a regression guard for this fix.

- **Generated-AST unit tests updated** in
  `test/bond/compiler/{annotated_function,assertion,invariants}_test.exs`
  to assert that wrapper → lifted-defp call sites route every argument
  through the `__opaque__/1` laundering helper (in `Bond.Predicates`)
  and that the lifted defps delegate the if/throw to `check_assertion/3` /
  `check_value/3` (in `Bond.Runtime.Eval`).

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.17.4] - 2026-05-28

A patch release fixing two Elixir 1.18+ compatibility issues, surfaced by a
new downstream-consumer integration test that compiles and Dialyzer-checks
the code Bond generates into a using module. Also expands the CI matrix to
five Elixir versions and eliminates a family of parallel-compile races
exposed by Elixir 1.19's more aggressive parallel compiler.

### Fixed

- **Invariant post-check no longer emits a struct `case` into user modules.**
  Elixir 1.18+'s type checker (under `--warnings-as-errors`) rejects a
  `case var!(result)` with struct clauses when the function's return type
  can't be a struct — for example `size/1` returning an integer — producing
  "the following clause will never match" warnings that fail downstream
  builds. The shape match moved into
  `Bond.Runtime.Eval.check_struct_invariant/3`, whose `result` is typed
  `term()`, eliminating the false positive. Runtime behaviour is unchanged.

- **`Bond.Runtime.Eval.should_evaluate?/3` type-spec widened.** The
  `chain_defaults` map's value type previously excluded `:purge`, but a
  function with no `@pre`/`@post` of its own (e.g. an invariant-only
  `size/1`) legitimately contributes `:purge` for those kinds. Dialyzer
  flagged the mismatch and cascaded into six spurious downstream findings
  for users running `mix dialyzer` on their projects.

### Internal

- **Downstream-consumer integration test added** (`integration/consumer`).
  A standalone Mix project that `use`s Bond is now compiled and
  Dialyzer-checked as part of CI. This is the test that surfaced the two
  fixes above.

- **CI matrix expanded from 3 to 5 cells.** Covers every Elixir minor
  from 1.14 to the current stable (1.19), each paired with the highest
  OTP it supports: 1.14.5/OTP 25.3, 1.16.3/OTP 26.2, 1.17.3/OTP 27.2,
  1.18.3/OTP 27.2, 1.19.5/OTP 27.2. Confirms the `~> 1.14` floor
  is accurate across the full matrix.

- **Parallel-compile races eliminated.** Elixir 1.19's more aggressive
  parallel compiler exposed race conditions where Bond's internal BEAM
  files could be read before they were fully written to disk. Fixed by:
  - Extracting `Bond.Compiler.CompileStateFSM.Server` from
    `compile_state_fsm.ex` into its own file.
  - Extracting `Bond.Compiler.AnnotatedFunction.Clause` from
    `annotated_function.ex` into its own file.
  - Changing `alias` to `require` in `bond.ex` and `compiler.ex` to
    establish a complete compile-dep chain that Mix's parallel scheduler
    enforces.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.17.3] - 2026-05-26

A small additive release: `_name` and `name` are now treated as semantically
equivalent in the consistent-naming check. Surfaced by a Photon dogfood
round where the fallback-clause idiom (`def f(_a, _b, c)` paired with a
contracted `def f(a, b, c)`) tripped the agreement rule unnecessarily.

### Changed

- **Underscore-prefixed top-level names normalize against their unprefixed
  counterparts** in `Bond.Compiler.Clauses.canonical_names/2`. `_a` and
  `a` agree at the same position; the canonical at that position is the
  non-underscored form. This matches Elixir's leading-underscore convention
  ("bound but intentionally unused" — the same parameter, just marked as
  not-used in the body).

      # 0.17.2 — `CompileError`: position 0 disagrees (`:_a` vs `:a`)
      # 0.17.3 — compiles cleanly
      @pre is_atom(a)
      def f(a, b, c) when is_atom(a), do: {:ok, a, b, c}
      def f(_a, _b, c), do: {:fallback, c}

  Wildcards (bare `_`, returned as `nil` from `top_level_name/1`) are
  unaffected — they continue to adopt sibling clauses' names rather than
  agreeing with `_a` directly.

- **`Bond.Compiler.Clauses.referenced_param_names/2`** treats both
  spellings symmetrically: a contract referencing `a` matches a clause
  binding `_a`, and a contract referencing `_a` matches a clause binding
  `a`. The intersection check is name-equivalent under the
  leading-underscore normalization.

### Internal

- 8 new unit tests in `Bond.Compiler.ClausesTest` for the normalization
  rules (agreement, all-underscored agreement, truly-different names
  still disagreeing, wildcard-vs-named-underscore distinction, both
  directions of `referenced_param_names` matching).

- 1 new behavioural test in `Bond.MultiClauseDispatchTest` driving the
  Photon-style fallback-clause idiom end-to-end.

- FAQ entry "How are multi-clause functions handled?" gains a paragraph
  on the `_name`/`name` equivalence.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.17.2] - 2026-05-26

A purely additive release narrowing the 0.17.0 consistent-naming rule from
"all positions must agree" to "positions referenced by some contract must
agree." Surfaced by a second round of Photon dogfooding where a trivial
result-only contract on a four-clause shape-dispatching function would
otherwise have required renaming every parameter across all clauses.

### Changed

- **Multi-clause consistent-naming check is now per-position based on
  contract references.** A contract that doesn't reference any parameter
  name imposes no naming constraint:

      # 0.17.0 — `CompileError`: position 1 disagrees on :game vs :league
      # 0.17.2 — compiles cleanly
      @post is_boolean(result)
      def can_access?(conn, %Game{} = game, %GameFilm{} = film), do: ...
      def can_access?(conn, league, conference) when is_binary(league), do: ...

  Bond walks every `@pre`/`@post`/`@invariant` expression's AST and
  collects bare-variable references, intersecting with the union of
  top-level parameter names across all clauses. Synthetic bindings
  (`result`, `old(...)` helpers, the invariant `subject`) drop out of
  the intersection automatically. Agreement is required only at
  positions whose canonical name appears in the resulting set.

  Adding a contract that *does* reference a disagreeing position
  re-engages the rule at that position — the `CompileError` fires
  exactly when (and where) a contract needs the consistency. Trivial
  contracts attach freely; shape-dependent contracts still need
  `~>` for cross-clause uniformity.

### Added

- **`Bond.Compiler.Clauses.referenced_param_names/2`** — new internal
  helper. Walks an assertion list's expression ASTs collecting
  bare-variable names, intersected with the union of top-level
  parameter names across all clauses.

- **`Bond.Compiler.Clauses.assert_clauses_agree!/4`** — gains a fourth
  argument for the set of names requiring agreement. The 3-arg form
  remains (defaulting to `:all`) for strict-mode callers and existing
  tests.

### Fixed

- `Bond.Compiler.Clauses.rewrite_clause_params/3` now correctly rebinds
  the canonical name when a clause's top-level name differs from it.
  This case couldn't arise under 0.17.0's strict rule but does under
  the 0.17.2 relaxation (at unreferenced positions where the canonical
  is a generated `bond_arg_<idx>` regardless of what the user named
  the parameter). Without the rebind, the wrapper would reference an
  unbound name at the super-call site.

### Internal

- 13 new unit tests in `Bond.Compiler.ClausesTest` covering the AST
  walker (bare/remote/operator/`old`/`subject` references, the
  cross-clause candidate-name union, and the documented closure-
  variable false-positive case) and the relaxed mode of
  `assert_clauses_agree!/4` (`:all`, empty, agreeing, disagreeing
  required-name sets).

- 2 new behavioural tests in `Bond.MultiClauseDispatchTest` covering
  the Photon-shape relaxation and the re-engagement when a parameter-
  referencing contract is added.

- FAQ entry "How are multi-clause functions handled?" gains a
  subsection describing the positional rule and the trivial-contract
  affordance.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.17.1] - 2026-05-26

A purely additive release closing a doc-symmetry gap: per-function
`@pre`/`@post` already get rendered into each function's `@doc` as
`#### Preconditions` / `#### Postconditions` sections, but module-level
`@invariant` declarations had no rendered home. Readers landing on a
struct module's docs page couldn't see what invariants the module
ensures unless the author had hand-written them up.

### Added

- **Auto-generated `## Invariants` moduledoc section** for any module
  with `@invariant` declarations. The section names the struct, explains
  the implicit `subject` binding (so readers without prior Bond context
  can read the assertions), lists each invariant in the same
  `label: expression` form used by per-function contract docs, and notes
  when invariants fire plus the `defp` exemption.

  ```
  ## Invariants

  Bond ensures the following invariants hold for every value of
  `%BoundedStack{}` produced by or passed into this module's public API.
  Inside each assertion, `subject` refers to the value being checked.

      non_negative_capacity: subject.capacity >= 0
      size_within_capacity: length(subject.items) <= subject.capacity

  These invariants are checked automatically on entry to and exit from
  every public function in this module. Private functions are exempt by
  the Eiffel convention.
  ```

  Special cases:

    * Users who already wrote a `@moduledoc` get the generated section
      appended after their authored content.
    * Users who wrote `@moduledoc false` have their decision respected
      — no section is added and the module remains hidden.
    * Users with `@invariant` but no `@moduledoc` get a moduledoc
      synthesised containing just the Invariants section, so the
      contracts surface in the generated docs.
    * `:invariants` set to `:purge` (compile-time disable) suppresses
      the auto-generated section, matching the per-function
      contract-doc suppression rule.

### Changed

- **`Bond.Compiler.ContractDocs.moduledoc_invariants_section/3`** —
  new internal function producing the markdown section. Reuses the same
  `label: expression` formatting as the existing per-function doc
  generation so labelled and bare invariants render consistently across
  function-level and module-level contract docs.

- Bond's `__before_compile__` hook now augments the user module's
  `:moduledoc` attribute via `Module.put_attribute/3` at compile-end,
  reading the current value and appending the generated section.

- **README's `@invariant` section** gains a new "Generated
  documentation" subsection describing the auto-generation behaviour
  and the special cases above.

### Internal

- New test/support fixtures
  (`BondTest.SynthesizedModuledocInvariant`, `…HiddenModuledocFixture`,
  `…PurgedInvariantsFixture`) exercise the synthesised, hidden, and
  purge code paths. 17 new tests across `Bond.Compiler.ContractDocsTest`
  (unit) and `Bond.ModuledocInvariantsTest` (end-to-end via
  `Code.fetch_docs/1`).

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.17.0] - 2026-05-26

0.17.0 closes the longest-standing bug surfaced by real-world dogfooding:
multi-clause functions whose first body clause had shape-specific
patterns silently broke callers using a different shape. The fix is a
per-clause wrapper redesign that preserves Elixir's natural multi-clause
dispatch, plus a new rule that all clauses must agree on the top-level
parameter name at each position when Bond is attaching contracts.

0.17.0 also fixes a latent semantic bug in `Bond.Predicates.~>/2`: the
implication operator was a `def`, so both sides were eagerly evaluated.
The natural "shape-dependent assertion" pattern
(`is_struct(x, Mod) ~> (x.id > 0)`) crashed on non-struct inputs to the
antecedent. `~>` is now a `defmacro` that short-circuits.

### Breaking changes (minor)

- **`Bond.Predicates.~>/2` is now a macro, not a function.** The
  expansion is `if antecedent, do: !!consequent, else: true`, so the
  consequent is only evaluated when the antecedent is truthy. This
  matches the logical reading of implication and makes
  shape-dependent assertions safe to write.

      # Was: both sides evaluated eagerly — `String.length(x)` raised
      # FunctionClauseError when `x` wasn't a binary.
      @pre is_binary(x) ~> (String.length(x) > 0)

      # Now: `String.length(x)` is only evaluated when `is_binary(x)`
      # is truthy. Same source, correct semantics.

  The migration impact is limited: code that passed `~>` as a function
  capture (`&Bond.Predicates.~>/2`) no longer compiles. Use a function
  wrapper or the underlying `implies?/2` (still a function and still
  eagerly evaluated) instead. The infix usage that's common in
  contracts is unchanged.

- **Multi-clause functions with contracts must agree on top-level
  parameter names across all clauses.** Heterogeneous naming raises
  `CompileError` at the function's compile site. Pre-0.17.0 Bond used
  the first clause's params for the wrapper head verbatim, silently
  breaking callers whose shape matched a non-first clause; the new
  rule makes the constraint explicit and pushes naming consistency
  (often a readability win regardless of Bond).

      # Was (silently broken): callers passing strings hit
      # FunctionClauseError inside Bond's generated code.
      def lookup(conn, %Game{} = g, %GameFilm{} = f), do: ...
      def lookup(conn, league, conference) when is_binary(league), do: ...

      # Now: rename for consistent positional meaning across clauses.
      def lookup(conn, %Game{} = resource, %GameFilm{} = scope), do: ...
      def lookup(conn, resource, scope) when is_binary(resource), do: ...

  Wildcard clauses (`def f(_)`) and literal-pattern clauses
  (`def f(0)`) don't bind a top-level name at that position — they
  adopt whatever name a sibling clause provides. So the common
  `def try_init(_)`-paired-with-`def try_init(capacity)` pattern
  works unchanged.

  For shape-dependent assertions across clauses, use the `~>`
  implication operator (which now short-circuits, per above).
  Per-clause contracts may be added in a future release if the
  consistent-naming restriction turns out to bite real code.

### Added

- **`Bond.Compiler.Clauses`** — new internal module owning clause-
  shape utilities: `top_level_names/1`, `canonical_names/1`,
  `assert_clauses_agree!/3` (the validator), `rewrite_clause_params/3`
  (canonical-name binding + underscore-prefix of unused names), and
  `underscore_prefix_unused/2`.

- **`Bond.Compiler.ClauseWrapper`** — new internal module owning
  per-clause wrapper emission. Extracted from `AnnotatedFunction`
  (which is on the FSM's hot path) to keep that file small and avoid
  the parallel-compile race the project first encountered in 0.13.0.

### Changed

- **Wrapper emission switches from single-wrapper to per-clause.**
  For an N-clause user function, Bond now emits N wrapper clauses,
  each preserving the user's pattern (with destructured names
  underscore-prefixed where the wrapper body doesn't reference them).
  Elixir's natural multi-clause dispatch routes each call to the
  appropriate user clause via `super/N`. Wrong-shape inputs raise
  `FunctionClauseError` at the wrapper layer, matching the pre-Bond
  behaviour.

- **Lifted assertion defps' parameter heads diverge by clause count.**
  - Single-clause functions keep the user's pattern in the lifted
    defp head, so contracts can still reference destructured names
    from the head (e.g. `current_count` from
    `%__MODULE__{count: current_count} = state` — the
    contracts-and-concurrency guide example works unchanged).
  - Multi-clause functions use the canonical top-level names as bare
    vars. Contracts can only reference those names; shape-dependent
    assertions use `~>`.

- **Destructure-in-head wrapper warnings (the original #3 from the
  Photon dogfood) are silenced.** Bond's per-clause wrapper now
  underscore-prefixes any destructured name the wrapper body doesn't
  reference. The lifted defp's pattern (for single-clause functions)
  still binds those names, so contract-side access is unaffected.

### Internal

- **`Bond.Compiler.Invariants` simplifications.** The destructure-only
  invariant handling that ran in 0.16.x is subsumed by the canonical-
  name rewrite — `Invariants.rewrite_call_params/2` and
  `Invariants.params_split/3` are no longer called from emission.
  They remain in the module for now; cleanup deferred to a later
  release.

- **`Bond.Compiler.AnnotatedFunction` shrunk from 448 → 430 lines**
  via the ClauseWrapper and Clauses extractions, well below the
  historical baseline where the parallel-compile race surfaced.

- **Test fixture migration.** The existing `BondTest.InvariantSmoke.
  try_new/1` (wildcard adopts canonical) and `BondTest.Stack.new/N`
  (all clauses agree on `capacity`) work unchanged under the new
  rule. The unit-test fixture in `Bond.Compiler.AnnotatedFunctionTest`
  (previously `list`/`map`) migrated to consistent `input`.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.16.2] - 2026-05-26

A patch release covering eight issues surfaced by dogfooding Bond 0.16.1
on a real-world Elixir umbrella application (Photon, ~200+ modules). Six
fixes bundle here; two (#2 wrapper-head shape leak, #3 destructure-in-
head unused warnings) are deferred to 0.17.0 pending a design
conversation.

### Changed

- **Remote function calls are now valid as the outermost expression of
  an assertion.** Pre-0.16.2, `@pre String.starts_with?(x, "foo")` was
  rejected by `Bond.Compiler.Assertion.is_assertion_expression/1` —
  the AST's head is a `{:., _, _}` 3-tuple, not an atom, so the guard
  failed. Workaround was an `== true` suffix on every such assertion.
  The relaxed guard accepts the remote-call shape, including
  `Map.has_key?(m, :k)`, `Enum.all?(xs, &f/1)`,
  `String.starts_with?(s, "prefix")`, and Erlang calls
  (`:erlang.is_atom`).

- **No `@doc` emission on `defp`.** Contracts on private helpers
  previously triggered Elixir's "@doc is always discarded for private
  functions" warning on every contracted defp, making the combination
  unusable without compile-time noise. `Bond.Compiler.ContractDocs.
  doc_clauses/4` now short-circuits for `:defp` kind. The contracts
  themselves continue to fire — the warning was the only blocker.

- **`Bond.Predicates` moduledoc gains an "Operator precedence"
  section** documenting the `~>` / `<~` left-associativity trap.
  `A ~> pattern <~ B` parses as `(A ~> pattern) <~ B`, where the LHS
  of `<~` becomes an arbitrary expression containing `_` and fails to
  compile. The fix is parens around the inner operator. Same trap
  surfaced as a boxed callout in the main moduledoc's Assertion Syntax
  section so readers see it before they fall into it.

- **Telemetry section** gains a concrete metadata-map example showing
  the `{name, arity}` shape of `:function`, the sorted-binding-list
  shape of `:binding`, and a note on `:assertion_id` stability for
  aggregation pipelines.

- **Assertion Syntax section** in the moduledoc now shows remote-call
  examples and explicitly notes which forms aren't valid (bare
  literals, bare variables, non-call expressions).

### Fixed

- **`@pre is_binary(x), positive: x > 0`** (bare assertion mixed with
  a labelled one) and `@pre is_integer(x), x > 0` (two bare assertions
  in a single call) previously fell through to Kernel's `@/1` and died
  with "expected 0 or 1 argument for @pre, got: 2" — a confusing error
  that didn't point at the parse issue. Bond now matches these shapes
  at the macro layer and raises a clear `CompileError` suggesting
  either label-every-assertion (keyword-list form) or separate
  `@pre`/`@post` lines. Same catch-all added for `@invariant`.

- **Bond-shaped diagnostics on malformed assertions.** When the user
  wrote an assertion that didn't satisfy `is_assertion_expression/1`
  (`@pre 42`, `@pre :foo`, `@pre "hello"`), Bond previously surfaced
  a bare `FunctionClauseError` from `Assertion.new/5` with a
  stacktrace that dumped the full `Macro.Env`. New
  `Bond.Compiler.Assertion.validate_expression!/2` is called from both
  `register_assertion/5` and `register_invariant/4`, and raises
  `CompileError` with the env's file/line, the expression's source
  (via `Macro.to_string/1`), and a one-sentence hint at valid forms.

### Internal

- **Test coverage filled across each fix** (+36 tests, 256 total):
  - 6 unit tests in `assertion_test.exs` for the relaxed AST guard
    plus the new `validate_expression!/2` validator.
  - 8 behavioural tests in a new `BondTest.RemoteCallAssertions`
    fixture proving remote-call assertions work end-to-end in `@pre`,
    `@post`, `@invariant`, and `check/1` — both success and violation
    paths.
  - 4 behavioural + diagnostic tests for `defp` contracts, including
    a `capture_io(:stderr, ...)` assertion that no `@doc`-discarded
    warning fires during compilation.
  - 9 behavioural tests covering the new bare-vs-labelled
    `CompileError` catch-alls and verifying all five existing valid
    forms still compile cleanly.

### Deferred (to 0.17.0)

- **#2 wrapper-head shape leak.** Bond's override head uses the first
  body clause's params verbatim, so multi-clause functions with a
  shape-specific first clause silently break callers using a different
  shape (a `def fn(conn, %Game{}, %GameFilm{})` clause alongside a
  sibling `def fn(conn, league, conference) when is_binary(league)`
  clause will misroute string callers). The right fix needs a design
  conversation on whether to use a shape-neutral wrapper with
  restricted contract refs vs a per-clause wrapper that preserves
  dispatch faithfully.

- **#3 destructure-in-head wrapper warnings.** When the first body
  clause has destructure like `def f(%Mod{a: x, b: y} = z)` and the
  wrapper body uses only `z`, Elixir warns about unused `x`/`y`.
  Partially subsumed by #2's resolution.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.16.1] - 2026-05-22

A patch release covering a 1.0-prep test-coverage audit (no behavioural
change, just locking down behaviour that wasn't directly tested) plus
a refresh of the supporting guides for content that had drifted out of
date with 0.16.0.

### Changed

- **`guides/about.md` — full rewrite.** The previous version's feature
  TODO list still showed conditional compilation (shipped in 0.10/0.11)
  and invariants (shipped in 0.13) as unchecked items, and the framing
  read like marketing copy. New version is structured as "what Bond is,
  when to reach for it, background" — same length, every paragraph
  carrying information.

- **`guides/getting-started.md` — `@invariant` section added.** The
  tutorial previously mentioned `@invariant` only in "Next steps." A
  reader following it linearly would never learn there was a third
  contract kind. New section between "Inline checks" and "Disabling
  contracts in production" introduces it with a `BoundedStack` example
  and the `subject` binding, then points at the moduledoc for the full
  reference. The intro line at the top mentions `@invariant` alongside
  `@pre`/`@post`/`check/1`. The disabling-in-production config snippet
  now lists `:invariants` (was listing three of four keys).

### Fixed

- **`guides/faq.md` — "When does Bond check invariants?"** description
  brought current. The previous text said destructure-only function
  heads (`def foo(%__MODULE__{f: v}, ...)`, no `= name`) emit a
  compile-time warning and skip the pre-check. The 0.16.0 release
  lifted that restriction — Bond now rewrites the override clause to
  capture the struct under a generated name and the pre-check fires.
  Multi-struct heads are also noted (weren't previously).

- **`guides/getting-started.md` — dead anchor.** The "Next steps" link
  to the Invariants section used the pre-0.16.0 anchor
  `#module-invariants`; updated to `#module-invariant-for-struct-modules`
  matching the renamed section.

### Internal

- **Test coverage filled across seven gaps from a 1.0-prep audit**
  (+16 tests, 220 total; all green). No behavioural change — each
  fill verifies behaviour that was already in place but lacked a
  direct test:

    * **Invariant telemetry.** `[:bond, :assertion, :failure]` fires
      with `:kind => :invariant` on invariant violations. Documented
      since 0.13.0; previously only the other three kinds had
      assertions on the event.

    * **`@invariant` runtime modes.** Two tests cover (a) `put_env
      :bond, :invariants, false` skips evaluation, and (b) flipping
      back to `true` re-engages it. The runtime-toggle path was
      tested for `@pre`/`@post` but not `@invariant`.

    * **Compound `and` guards.** Behavioural confirmation that
      `is_struct(x, __MODULE__)` nested inside an `and` guard
      triggers the pre-invariant check. (Compiler-level detection
      was already covered.) The `or` case is deliberately not
      covered — it's a latent unsafe pattern worth a separate
      design discussion.

    * **No-struct heads.** Behavioural confirmation that a function
      whose head doesn't expose the struct silently skips pre-
      invariant evaluation — passing non-struct arguments returns
      cleanly rather than crashing on a `subject.<field>` access.

    * **Migration `CompileError`s.** The legacy `@invariant <name>,
      <expr>` and the two arity-2 `check` shapes (removed in 0.16.0)
      now have direct assertions that they raise `CompileError` with
      the migration message at the call site.

    * **`Bond.Test.assert_check_violation/2`.** The helper existed
      alongside its `precondition`/`postcondition`/`invariant`
      siblings but had no test.

    * **`old(...)` runtime integration.** Compiler-level extraction
      and precompilation were covered; the runtime path (does the
      snapshotted value end up correctly bound when the postcondition
      evaluates?) had no direct test. New `Bond.OldRuntimeTest`
      covers success and failure paths plus the captured `binding()`
      at failure.

- **Coverage audit findings worth keeping in mind for future
  releases** (not addressed in 0.16.1):

    * Compound `or` guards containing `is_struct(_, __MODULE__)` are
      a latent unsafe pattern. Bond's detection recognises `x` as the
      struct parameter, but the pre-invariant fires unconditionally —
      so a runtime input matching a non-struct alternative crashes in
      the invariant body rather than raising a clean
      `FunctionClauseError`.
    * Relatedly, the override clause doesn't reproduce the user's
      function-head guard. Calling `Smoke.reverse(5)` (where
      `reverse` has `when is_struct(stack, __MODULE__)`) hits Bond's
      pattern-less override, fires the pre-invariant against the
      integer, and crashes inside the invariant body before super
      dispatches to the user's def for the proper
      `FunctionClauseError`.

  Neither issue surfaces in normal use (callers pass arguments of
  the right shape) — they're worth a fix pass before 1.0 but not
  shippable as a patch.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.16.0] - 2026-05-22

0.16.0 is the first 1.0-prep release. It tightens the public API in two
places where the surface had accumulated friction: `@invariant` drops its
required binding-name argument in favour of an implicit `subject` binding,
and `check/2` drops its two string-label forms in favour of `check expr`
and `check label: expr`. Both legacy shapes now raise `CompileError` at the
call site with a migration message.

### Breaking changes (minor)

- **`@invariant <name>, <expr>` was removed.** The new form is `@invariant
  <expr_or_kw>` — no binding-name argument. Invariant expressions reference
  the implicit `subject` binding, which Bond rebinds at every check site to
  whichever struct parameter the function head exposes (detected
  automatically across `%__MODULE__{} = name` patterns, `is_struct(name,
  __MODULE__)` guards, and `%__MODULE__{...}` destructures).

      # Was:
      @invariant stack,
                 non_negative_capacity: stack.capacity >= 0,
                 size_within_capacity: length(stack.items) <= stack.capacity

      # Now:
      @invariant non_negative_capacity: subject.capacity >= 0,
                 size_within_capacity: length(subject.items) <= subject.capacity

  Function bodies don't change — `def push(%__MODULE__{} = stack, item)`
  keeps its parameter named `stack`; Bond detects and rebinds `subject` to
  it automatically. The legacy 2-arg shape raises a `CompileError` with the
  migration message.

- **`check/2` was removed.** The two string-label forms (`check "label",
  expr` and `check expr, "label"`) are gone — they were redundant with the
  keyword-list form, which already carries a label:

      # Was:
      check "x is a number", is_number(x)
      check is_number(x), "x is a number"

      # Now:
      check x_is_number: is_number(x)

  `check expr` (bare) and `check label: expr` (keyword) are the two
  remaining forms. The legacy 2-arg shape raises a `CompileError` with the
  migration message.

### Added

- **Multi-struct heads in `@invariant`.** `def merge(%__MODULE__{} = a,
  %__MODULE__{} = b)` now triggers invariant checks on *both* struct
  parameters in left-to-right order, with `subject` rebinding to each in
  turn. Previously only the first detected struct param was checked.

- **Destructure-only heads in `@invariant`.** `def head(%__MODULE__{items:
  [first | _]})` (no `= name`) now participates in pre-invariant checks.
  Bond rewrites the override clause head to add a capturing binding
  (`%__MODULE__{items: [first | _]} = __bond_subject_0__`) so the struct
  passes cleanly to the lifted invariants defp. Previously this shape was
  skipped silently with a documented (but unimplemented) warning.

  This also closes a latent bug in the override emission: `super(...)`
  previously spliced raw destructure patterns as expressions, which would
  fail at compile time on patterns like `[h | _]` if a user had ever tried
  it with `@pre`/`@post`. The capture rewrite passes the original input
  through cleanly.

- **`Bond.Compiler.Invariants.detect_struct_params/2`** — internal helper
  that finds every struct-bearing parameter in a function head, returning a
  list of `{:bound, var, idx}` or `{:destructure, idx}` descriptors.
  Replaces the single-struct `find_struct_arg/2` removed below.

### Changed

- **Doc-generation logic extracted into `Bond.Compiler.ContractDocs`.**
  Pure refactor — no user-visible change. Shaves ~80 lines off
  `Bond.Compiler.AnnotatedFunction`, which is on the FSM's hot path. A
  shorter `AnnotatedFunction` reduces the window for the parallel-compile
  race first encountered (and partially mitigated) in 0.13.0.

- **`Bond.Compiler.Assertion` drops the `:binding_name` field.** The
  invariant body now hardcodes the `subject = bond_invariant_value` rebind.
  The struct shrinks from 8 fields to 7.

- **`Bond.Compiler.Invariants` simplified.** Removed the legacy
  single-struct helpers `find_struct_arg/2`, `struct_arg/2`,
  `pre_invariant_stmts/5`, and the supporting AST walkers. New emission
  uses `detect_struct_params/2` + `all_pre_invariant_stmts/5` +
  `rewrite_call_params/2` end-to-end.

- **Moduledoc reorganised.** Sections regroup as "what you write" (Usage →
  Assertion syntax → `@invariant` → `check/1` → `old`) then "how you
  operate" (Documenting contracts → Conditional compilation → Telemetry →
  PBT). The 0.10 → 0.11 migration table is dropped, and the long Agent
  race-condition narrative in `old` moves to the
  `contracts-and-concurrency` guide.

- **Telemetry `:kind` documentation** updated to include `:invariant` (the
  event was already emitted since 0.13.0; the docs were stale).

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.15.0] - 2026-05-22

0.15.0 closes a correctness gap in conditional compilation: previously
`:preconditions`, `:postconditions`, and `:invariants` could be toggled
independently in any combination, including combinations that produced
diagnostically-misleading errors (e.g. postconditions on while
preconditions are off — a "postcondition failure" might really mean
the caller broke their contract, not the function).

0.15.0 enforces the natural chain `preconditions ≤ postconditions ≤
invariants` both at compile time and at runtime. `:checks` remains
independent of the chain.

### Breaking changes (minor)

- **Compile-time validation of `:purge` combinations.** `:purge` on a
  lower kind now requires `:purge` on every higher kind in the chain.
  `Bond.Compiler.resolve_config/3` raises `CompileError` with an
  explanation otherwise.

  Migration: if you used `config :bond, preconditions: :purge` without
  also purging postconditions/invariants, choose one:

      # Was:
      config :bond, preconditions: :purge

      # Option A — also purge the chain (preserves the original intent
      # if you wanted zero overhead):
      config :bond,
        preconditions: :purge,
        postconditions: :purge,
        invariants: :purge

      # Option B — runtime-disable instead of purge (keeps the code,
      # operator can flip on at runtime):
      config :bond,
        preconditions: false

  `false` is unaffected — runtime-disabling a single kind is
  unchanged. Only `:purge` participates in the compile-time check.

### Added

- **Runtime chain propagation.** When a lower kind is `false` at runtime
  (`Application.put_env(:bond, :preconditions, false)`), every higher
  kind is also skipped automatically, regardless of its own setting.
  Enforced in `Bond.Runtime.Eval.should_evaluate?/3` via the new
  optional third argument carrying the compile-time defaults of every
  lower kind.

- **One-time-per-process propagation log.** The first time a higher
  kind is skipped because a lower one is runtime-off, Bond emits a
  `Logger.warning` describing the chain constraint, the offending
  pair, and the `Application.put_env` invocation that would bring the
  higher kind back. Deduped per (higher, lower) pair via a
  Process-dictionary marker — long-running OTP processes get exactly
  one warning per pair.

### Changed

- `Bond.Runtime.Eval.should_evaluate?/2` is now `should_evaluate?/3`
  with an optional `chain_defaults` map; the 2-arity call still works
  via default and is unchanged behaviour-wise for `:preconditions` and
  `:checks` (both have no lower kinds).

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.14.0] - 2026-05-22

0.14.0 adds **`Bond.PropertyTest`** — a property-based testing layer that
uses Bond's contracts as the oracle. The hard part of PBT is usually
writing the predicate that distinguishes right from wrong outputs;
contracts already supply that at every call site. PBT just feeds random
inputs through already-instrumented code.

### Added

- **`Bond.PropertyTest.contract_holds/2`** — single macro, two forms:

  - **Form 1 (single function).** `contract_holds &Mod.fn/N, args: [gen0, ...]`
    expands to a property block that calls the function with random
    arguments and lets Bond's runtime contracts fail the property on
    any violation. StreamData shrinks to the minimal counterexample.

  - **Form 2 (module sequence).**
    `contract_holds Module, constructors:, transformers:, observers:`
    expands to a property block that generates random sequences of
    operations over a struct module and runs them. State is threaded
    through transformers; observers don't advance state but the
    pre-invariant still fires. The module's `@invariant`s are the
    oracle. Supports `%Mod{}` and `{:ok, %Mod{}}` return shapes;
    `{:error, _}` terminates the sequence cleanly. Common option
    `:name` overrides the auto-generated property description.

  The macro dispatches by first-arg AST shape (function reference vs
  module alias).

- **`use Bond.PropertyTest`** — brings in `ExUnitProperties` and imports
  the `contract_holds` macro. Raises a `CompileError` at the use site
  with installation instructions if `:stream_data` isn't available.

- **`Bond.PropertyTest.Sequence`** — internal helper module owning the
  sequence generator and runner used by Form 2.

- New FAQ entry: "How does Bond compose with StreamData /
  property-based testing?".

### Changed

- `:stream_data` moves from `only: [:dev, :test]` to a regular dep with
  `optional: true`. Users who want PBT now add `{:stream_data, "~> 0.6"}`
  to their own deps; users who don't pay no cost.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.13.0] - 2026-05-22

0.13.0 adds **`@invariant`** declarations for struct modules — module-scoped
properties that hold across every public function in the struct's defining
module. Where `@pre`/`@post` constrain a single function call, `@invariant`
constrains the struct itself.

### Added

- **`@invariant <name>, <kw_or_expression>`** annotation. Same shape as
  `@pre`/`@post`: a labelled keyword-list of assertions, or a single
  unlabelled expression. The first argument is the variable name the
  expression refers to (e.g. `stack` in
  `@invariant stack, length(stack.items) <= stack.capacity`).

  Invariants are checked at the boundaries of every public function in the
  module:

  - **On entry**, when the function head pattern-matches `%__MODULE__{} = name`
    or has an `is_struct(name, __MODULE__)` guard.
  - **On exit**, against the return value if it's `%__MODULE__{}` or
    `{:ok, %__MODULE__{}}`. Other return shapes fall through with no check.
  - **Never for `defp`** — private functions are exempt by the Eiffel
    convention (they often hold transiently-invalid state).

  When a function destructures `%__MODULE__{...}` in its head without binding
  the whole struct to a variable, Bond emits a compile-time warning suggesting
  `%__MODULE__{...} = name` to enable the pre-check.

- **`Bond.InvariantError`** — new exception parallel to
  `PreconditionError`/`PostconditionError`/`CheckError`. Raised on invariant
  violation; carries the same metadata shape.

- **`Bond.Test.assert_invariant_violation/2`** — ExUnit helper mirroring the
  existing pre/post/check helpers.

- **`:invariants` conditional-compilation key.** Joins `:preconditions`,
  `:postconditions`, and `:checks`. Same `true | false | :purge` value space;
  same runtime toggleability via `Application.put_env/3`; same `:overrides`
  and `use Bond, invariants: …` support.

- **`Bond.Compiler.Invariants`** — new internal module owning the invariant
  emission logic (struct-arg detection, pre-/post-invariant call sites, the
  lifted invariants defp). Kept separate from `Bond.Compiler.AnnotatedFunction`
  for separation of concerns and to avoid parallel-compile scheduling issues
  with the larger combined file.

### Changed

- `[:bond, :assertion, :failure]` telemetry events now also fire for invariant
  violations, with `:kind => :invariant` in the metadata. No subscriber
  changes are needed — existing handlers attached to the event automatically
  pick up the new kind.

- The internal `Bond.Compiler.Assertion` struct gains a `:binding_name` field,
  populated only on `:invariant` assertions from the declaration's first
  argument.

- `Bond.Compiler.AnnotatedFunction` gains an `:invariants` field plus
  `put_invariants/2` and `has_invariants?/1` helpers. `override?/1` widens to
  emit overrides for public functions in modules with `@invariant`s, even
  when the function has no per-function `@pre`/`@post`.

- `Bond.Compiler.CompileStateFSM` tracks module-scoped invariants alongside
  the per-function preconditions/postconditions. Invariants don't transition
  the FSM into `:contracts_pending` (they don't attach to a "next function")
  and aren't flushed by function definitions.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.12.0] - 2026-05-22

0.12.0 lands two internal-shape changes that compose on top of the
0.11.0 conditional-compilation work: contract closures move out of
override clauses into named private functions on the user's module
(reducing injected code per contract'd function), and `:telemetry`
events fire on assertion failures.

### Added

- **`[:bond, :assertion, :failure]` telemetry event.** Fires once per
  contract violation — `@pre`, `@post`, or `check` — immediately before
  the corresponding `Bond.PreconditionError` / `Bond.PostconditionError`
  / `Bond.CheckError` is raised. Single event family for all three
  kinds; consumers filter on the `:kind` metadata. Measurements carry
  `:system_time` and `:monotonic_time`; metadata carries `:kind`,
  `:module`, `:function`, `:label`, `:expression`, `:assertion_id`,
  `:file`, `:line`, and `:binding`. See the new "Telemetry" section in
  the `Bond` moduledoc / README. `{:telemetry, "~> 1.0"}` is now a
  regular dependency.

- **`Bond.Runtime.Eval.should_evaluate?/2`** — internal helper that
  performs the `Application.get_env/3` runtime guard. Used by the
  emission shape (see "Internal" below) to avoid allocating the
  assertion-evaluation closure when the runtime guard says skip.

### Changed

- **Per-function assertion closures are lifted into named `defp`s** on
  the using module: `__bond_preconditions__<fun>__<arity>` and
  `__bond_postconditions__<fun>__<arity>`. The override clause itself
  is now a small wrapper that calls these via
  `Bond.Runtime.Eval.evaluate_preconditions/1` /
  `evaluate_postconditions/1`. The big inline assertion-evaluation AST
  that used to be re-emitted into every override is gone; the BEAM
  carries one tiny override + one defp per non-purged kind, rather
  than the whole eval body inlined per function.

- **Runtime guard moved into `Bond.Runtime.Eval`.** The override calls
  `should_evaluate?(:preconditions, <compile_time_mode>)` and only
  builds the assertion-evaluation closure when that returns `true`.
  The `Application.get_env/3` lookup logic lives entirely in
  `Bond.Runtime` rather than being inlined at every contract'd
  function.

- **`Bond.check/1,2` routes through the same throw/catch path as
  `@pre`/`@post`.** All three kinds now produce
  `{:assertion_failure, info}` throws caught by `Bond.Runtime.Eval`,
  which fires the telemetry event and raises. This unifies the
  plumbing across the three kinds; previously `check` raised inline.

- **Stacktrace pruning** now also filters frames whose function name
  starts with `__bond_` (the lifted defps), so failures continue to
  point at the user's call site rather than into Bond-generated
  plumbing.

- **Benchmark** on the project fixture
  (`bench/runtime_check_overhead.exs`, trivial `@pre is_number(x)` in a
  tight loop):

  | mode    | 0.11.0   | 0.12.0   |
  |---------|----------|----------|
  | `:purge`  | ~48 ns   | ~34 ns   |
  | `true`    | ~155 ns  | ~143 ns  |
  | `false`   | ~89 ns   | ~91 ns   |

  The `true` path improves because the override no longer re-emits the
  full assertion-eval AST inline. The `false` (runtime-skip) path is
  flat within noise — `should_evaluate?/2` short-circuits before the
  closure is allocated.

### Fixed

- `Bond.CheckError`'s `message/1` no longer crashes when the error's
  `:function` metadata is missing (regression introduced and fixed
  internally during the `check` plumbing unification).

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.11.0] - 2026-05-21

0.11.0 reshapes the conditional-compilation config introduced in 0.10.0
around a new value space — `true | false | :purge` per kind — and adds two
new features that compose on top of it: runtime toggling without
recompilation, and per-module overrides.

### Breaking changes (minor)

- **`config :bond, <kind>: false` no longer compiles contracts out.** It
  now means "compiled in, runtime guard defaults to off." If you used
  `false` in 0.10.0 to get zero-overhead behaviour, change it to `:purge`
  to preserve that behaviour. `true` continues to work as before (with the
  addition of runtime toggleability — see below).

### Added

- **`:purge` mode for each contract kind.** Setting any of `:preconditions`,
  `:postconditions`, or `:checks` to `:purge` causes Bond to emit no code
  for that kind. The resulting BEAM contains no contract logic; per-call
  overhead is zero. Contract documentation for that kind is also
  suppressed.

- **Runtime toggling.** When a kind is compiled with `true` or `false`, the
  emitted override carries a runtime guard:
  `Application.get_env(:bond, <kind>, <compile_time_value>)`. The contract
  is evaluated unless the runtime value is exactly `false`. Operators can
  flip contracts on or off via `Application.put_env/3` from a remote
  console — no recompilation needed. The compile-time value sets the
  default for the runtime guard.

  Benchmark on the project fixture (`bench/runtime_check_overhead.exs`,
  trivial `@pre is_number(x)` in a tight loop): `:purge` ~48 ns/call,
  `false` ~89 ns/call (~40 ns guard overhead), `true` ~155 ns/call (guard
  plus assertion eval).

- **`:overrides` config for per-module rules.** A list of
  `{Module | Regex, opts}` tuples. Module-atom keys match exactly; `Regex`
  keys match against the source-visible module name (no `Elixir.` prefix).
  Use this to opt specific modules in or out of contract compilation
  without touching their source. Example:

      config :bond,
        preconditions: true,
        overrides: [
          {MyApp.HotPath, preconditions: :purge, postconditions: :purge},
          {~r/Workers\\./, postconditions: false}
        ]

- **`use Bond, opts` per-module options.** Pass any of `:preconditions`,
  `:postconditions`, `:checks` directly at the `use` site to override
  global and `:overrides` settings for that module.

      defmodule MyApp.HotPath do
        use Bond, preconditions: :purge, postconditions: :purge
      end

  Precedence: `use Bond` opts > exact-atom `:overrides` match > first
  `Regex` `:overrides` match > global config.

- **`Bond.Compiler.resolve_config/3`** — internal helper exposed for
  testing that combines global config, `:overrides`, and `use Bond` opts
  into the final per-module mode map.

### Changed

- `Bond.Compiler.AnnotatedFunction.apply_contract/2` now expects each kind
  in the config map to be `true | false | :purge` rather than a boolean.
  The function returns `nil` when both kinds resolve to `:purge`; in all
  other cases it emits the override with the appropriate runtime guards.

- `Bond.check/1,2` now expands to a runtime-guarded call when the resolved
  `:checks` mode is `true` or `false`, and to `:ok` (a compile-time no-op)
  when the mode is `:purge`.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.10.0] - 2026-05-21

The headline feature of 0.10.0 is **conditional compilation** of contracts.
You can now compile some or all of your contracts out entirely via
application config, with zero per-call overhead for disabled contracts. The
release also adds an ExUnit helper module, polishes error reporting, and
substantially rewrites the user-facing documentation.

### Added

- **Conditional compilation via `:bond` application config.** Three keys,
  read at compile time via `Application.compile_env/3`:
  - `:preconditions` (default `true`) — when `false`, no precondition
    evaluation is emitted in override clauses, and the auto-generated
    `#### Preconditions` doc section is omitted.
  - `:postconditions` (default `true`) — same for postconditions.
  - `:checks` (default `true`) — when `false`, every `check/1,2` macro
    call in modules that `use Bond` expands to `:ok` and the wrapped
    expression is **not evaluated**. (Don't put side effects inside
    `check`.)

  When both `:preconditions` and `:postconditions` are disabled for a
  function, Bond emits no override at all. The function runs exactly as
  written, with zero per-call overhead. The function's auto-generated
  contract docs are also suppressed in that case.

  See the new "Conditional compilation" section in the `Bond` moduledoc.

- **`Bond.Test` module** with `assert_precondition_violation/2`,
  `assert_postcondition_violation/2`, and `assert_check_violation/2`
  macros for testing contract violations in ExUnit. Field expectations
  (`:label`, `:expression`, etc.) can be exact values or `Regex` patterns.

- **New `guides/faq.md`** answering the questions that come up most: why
  contracts when I have ExUnit, will contracts slow down prod, how does
  Bond compare to Norm, what does Bond do that typespecs don't, the
  Assertion Evaluation rule, default-arg behaviour, multi-clause handling.

### Changed

- **Assertion failure messages pretty-print the captured `binding/0`** with
  `inspect/2 ... pretty: true, limit: 20, printable_limit: 200, width: 80`,
  so small bindings stay compact and large structs no longer dominate the
  failure output.

- **Stack traces of raised assertion exceptions are pruned** to omit
  `Bond.*` frames. Failures point at the user's call site rather than
  into `Bond.Runtime.Eval`.

- **`Bond` moduledoc / README restructured.** Leads with a five-line
  `Account.withdraw` example and a one-paragraph elevator pitch. The
  Wikipedia quote moves out. Assertion syntax recommends the keyword-list
  form as primary. New `Conditional compilation` section. The `Math.sqrt`
  example remains as the "showing everything" sample.

- **`guides/getting-started.md` expanded** into a step-by-step walkthrough:
  first `@pre`, postcondition with `result`, labelled assertions,
  predicates, `old` expressions, inline checks, disabling in prod, and
  ExUnit integration.

### Internal

- New private function in `Bond.Runtime.Eval` that prunes Bond frames from
  the captured stack trace before raising.
- `Bond.Compiler.AnnotatedFunction.apply_contract/1` is now
  `apply_contract/2` taking a `contract_config` map.
  The `__before_compile__/1` callback reads the config from a
  `@__bond_contract_config__` module attribute set by Bond's `__using__/1`.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.9.1] - 2026-05-21

A patch release covering documentation cleanup left over from the 0.9.0
refactor plus a handful of usability improvements.

### Added

- `.formatter.exs` is now published with the Hex package and declares
  `locals_without_parens` for `check/1`, `check/2`, and `old/1`. Downstream
  projects can pick these up with `import_deps: [:bond]` in their own
  `.formatter.exs`.
- Assertion-failure messages now include an `at: <file>:<line>` line so the
  source location is clickable in editors.

### Changed

- `binding/0` captured in assertion-failure info is sorted by name so
  failure messages are reproducible across runs.

### Fixed

- README/moduledoc no longer references the removed Bond.def/2 and
  Bond.defp/2 macros, eliminating `mix docs` cross-reference warnings.
- The `getting-started` guide installation hint now references the current
  version.
- CHANGELOG no longer auto-links the removed `define_function_with_contract/4`
  helper.

### Internal

- Removed the vestigial `:context` field from `Bond.Compiler.Assertion`.
- Tightened the `Bond.Compiler.AnnotatedFunction` moduledoc.

## [0.9.0] - 2026-05-21

This release is a large internal refactor with no breaking changes to the
public API. `@pre`, `@post`, and `check/1,2` all behave the same as in 0.8.x.

### Changed

- **Bond no longer overrides `Kernel.def/2` and `Kernel.defp/2`.** Contracts
  are now applied via Elixir compiler hooks (`@on_definition`,
  `@before_compile`, `@after_compile`). This makes Bond more robust against
  changes in Elixir's macro expansion semantics, eliminates a class of
  macro-hygiene issues, and plays nicer with other macros that produce
  function definitions.
- **Multi-clause functions are now wrapped by a single override clause that
  delegates to `super/1`** rather than having contract logic inlined into
  each clause. Elixir's normal pattern matching handles dispatch inside the
  `super` call.
- **Assertion failures are signalled by a throw / catch** instead of being
  raised inline. Each `@pre`/`@post` group compiles to an anonymous function
  that throws `{:assertion_failure, info}` on the first failure;
  `Bond.Runtime.Eval` catches it and raises the appropriate exception type.
- Functions with contracts now get auto-generated `Preconditions` and
  `Postconditions` sections in their documentation even if the user did not
  attach a `@doc` themselves. Previously contract documentation was only
  emitted when a `@doc` was present.
- Internal modules are reorganised into `Bond.Compiler.*` (compile-time) and
  `Bond.Runtime.*` (run-time) namespaces.

### Internal

- New modules: `Bond.Compiler.AnnotatedFunction` (multi-clause function
  model), `Bond.Compiler.FunctionDefinition`, `Bond.Compiler.CompileStateFSM`
  (rewritten), `Bond.Runtime.Eval`.
- Removed internal modules `Bond.Compiler.AnnotatedFunctionClause` and
  `Bond.Compiler.LegacyCompileStateFSM`, along with the
  `define_function_with_contract/4` helper they used.
- `Bond.Compiler.Assertion` now carries a stable random `:id` for use in
  error reporting and future internal tooling.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.8.3] - 2024-11-08

Released before this changelog was established. See the git history for
details.
