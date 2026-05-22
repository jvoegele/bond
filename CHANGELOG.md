# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [0.16.0] - 2026-05-26

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

## [0.15.0] - 2026-05-25

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

## [0.14.0] - 2026-05-24

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

## [0.13.0] - 2026-05-23

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
