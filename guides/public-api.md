# Public API surface (1.2)

This page enumerates every callable, attribute, and configuration value Bond
considers part of its **public surface** under the [stability
guarantees](stability.md). If something Bond exposes isn't on this list, it's
implementation detail — Bond reserves the right to change it without a
deprecation cycle. If you depend on something here, you can expect it to stay
backwards-compatible until the next major.

The full set of modules in published API docs is the source-of-truth for
"public module":

  * `Bond`
  * `Bond.Behaviour`
  * `Bond.Protocol`
  * `Bond.Predicates`
  * `Bond.Test`
  * `Bond.PropertyTest`
  * `Bond.PreconditionError`
  * `Bond.PostconditionError`
  * `Bond.InvariantError`
  * `Bond.CheckError`

Everything under `Bond.Compiler.*` and `Bond.Runtime.*` is internal (marked
`@moduledoc internal: true` and filtered out of hexdocs by `filter_modules`
in `mix.exs`). Code that calls into those namespaces is using a private API
and may break on a patch release.

## Module-attribute syntax (in `use Bond` scope)

By default Bond overrides `Kernel.@/1` while `use Bond` is in scope to
intercept four attribute names; everything else forwards through to
`Kernel.@/1` unchanged (verified by `test/bond/attr_compat_test.exs`).
(Under `at_annotations: false` the override is disabled and the qualified
`Bond.pre`/`Bond.post`/`Bond.invariant` calls are used instead — see
"Qualified-call syntax" below.) The accepted forms for the intercepted
attributes are:

### `@pre` and `@post`

  * `@pre expr` — bare expression. Recognised forms are documented in the
    `Bond.Predicates` moduledoc.
  * `@pre label: expr, other_label: other_expr` — keyword list of
    `label: expression` pairs. Labels are atoms; quote the key for spaces or
    punctuation (`@pre "must be positive": x > 0`).
  * `@post` accepts all the same forms. In addition, `result` is bound to the
    function's return value, and `old(...)` (see below) is recognised inside
    a postcondition expression.

The keyword-list form is the only labelling syntax. The positional forms
`@pre label, expr` and `@pre expr, label` were removed in 1.0 and raise a
`CompileError` pointing at the keyword form. Mixing a bare assertion with a
labelled assertion in a single annotation (e.g. `@pre is_binary(x), positive:
x > 0`) likewise raises a `CompileError` with a specific diagnostic.

### `@invariant`

  * `@invariant expr` — single expression. Implicit binding `subject`
    references the value being checked.
  * `@invariant label: expr, other_label: other_expr` — keyword list of
    labelled invariants. Bare-form unlabelled, single-expression syntax also
    works.

The 2-argument legacy form `@invariant name, expr` was removed in 0.16.0 and
raises a `CompileError` pointing at the migration.

### `@doc`

  * `@doc` is intercepted to append `#### Preconditions` and `#### Postconditions`
    sections (if any) to the user-authored docstring. The intercepted
    behaviour is part of the public surface; the exact rendering of those
    sections is documented under `Bond` and is part of the public surface as
    well.

## Qualified-call syntax (`at_annotations: false`)

For modules that opt out of the `@` override with `use Bond, at_annotations: false`,
contracts are written as fully-qualified macro calls. These register into the
same compiler machinery as the `@` forms and accept the same arguments:

  * `Bond.pre/1`, `Bond.post/1` — bare expression or keyword list of
    `label: expression` pairs (the same single-form labelling as `@pre`/`@post`;
    quote the key for spaces or punctuation).
  * `Bond.invariant/1` — single expression or keyword list of labelled
    invariants; references the implicit `subject` binding.

These macros are **never imported** (even under the default `at_annotations: true`),
so they cannot collide with user function names; they are only ever reached
through the `Bond.` prefix.

## Macros and operators (after `use Bond`)

  * `check/1` — runtime assertion of an expression or a keyword list of
    labelled expressions. Behaviour under the four `:checks` modes
    (`true | false | :purge`) is documented in the main `Bond` moduledoc.
  * `old/1` — captures a value at function-entry for use in a `@post`
    expression. Only valid inside `@post`.
  * `subject` — implicit binding inside `@invariant` expressions, bound to
    the struct being checked at each check site.
  * `~>/2`, `<~/2` — pattern-matching operators imported from
    `Bond.Predicates`. Precedence and associativity are documented in the
    `Bond.Predicates` moduledoc.
  * `|||/2`, `xor/2`, `implies?/2` — boolean operators imported from
    `Bond.Predicates`. See "Bond.Predicates" below for direct calls outside
    a Bond module.

## `use Bond` options

Each option is one of `true`, `false`, or `:purge` unless noted. Options
passed to `use Bond` override both the global `:bond` application config and
any `:overrides` entry that matches the module:

  * `:preconditions` — mode for the module's `@pre` annotations.
  * `:postconditions` — mode for the module's `@post` annotations.
  * `:checks` — mode for the module's `check/1` calls.
  * `:invariants` — mode for the module's `@invariant` annotations.
  * `:at_annotations` — boolean (default `true`). When `false`, Bond does not
    override `Kernel.@/1` in the module, so the `@pre`/`@post`/`@invariant`
    forms are unavailable and contracts must be written as the qualified
    `Bond.pre`/`Bond.post`/`Bond.invariant` calls (see below). Use it to
    coexist with another library that overrides `@` (e.g. Norm's
    `@contract`). See the FAQ entry "Can I use Bond and Norm in the same
    module?"
  * `:warn_skipped_invariants` — boolean (default `true`). Controls the
    compile-time warning Bond emits when a public function in an
    invariant-declaring module has no clause that pattern-matches the
    struct or returns one. See the FAQ entry "Why is Bond warning about
    skipped invariants?"
  * `:behaviours` — a module or list of `Bond.Behaviour` modules whose callback
    contracts this module inherits and enforces. Also emits `@behaviour` for
    each. See "Contract inheritance" below.

## Per-function module attribute

  * `@bond_warn_skipped_invariants` — tri-state (omit / `true` / `false`),
    consumed by Bond's `__on_definition__` handler and scoped to the **next**
    `def` only. Omitting the attribute inherits the module/global setting;
    `false` suppresses the warning for that single function; `true` re-
    enables the warning for that single function even under a module-wide or
    global `false`.

## Contract inheritance

Two modules let an abstraction declare contracts that every implementation
enforces. Both are part of the public surface; the full rules are in the
[Contract Inheritance for Behaviours](contract-inheritance.md) and [Contract
Inheritance for Protocols](protocol-contracts.md) guides.

  * **`Bond.Behaviour`** — `use Bond.Behaviour` in a behaviour module enables
    `@pre`/`@post` immediately preceding each `@callback`. The accepted contract
    forms are the same as `@pre`/`@post` under `use Bond` (bare or labelled
    keyword list); contract expressions reference the callback's argument names
    and `result`. A module inherits them with `use Bond, behaviours: […]`.
  * **`Bond.Protocol`** — `use Bond.Protocol` in a `defprotocol` enables
    `@pre`/`@post` immediately preceding each `def`. Contracts are enforced at
    the protocol's dispatch boundary across all implementations; expressions
    reference the function's declared argument names and `result`.

Inherited contracts are immutable: an implementation cannot weaken, strengthen,
or refine them. The *fact* that the documented compile-time rules fire (e.g. an
impl `@pre`/`@post` on an inherited operation is rejected; a contract may
reference only declared names) is part of the public surface; the exact wording
of those diagnostics is not.

## `Bond.Predicates`

When called directly (i.e. not through `use Bond`), `Bond.Predicates`
provides:

  * `xor/2`, `implies?/2`, `|||/2` — `def`s. Takes two `as_boolean(term())`
    arguments, returns `boolean()`.
  * `~>/2`, `<~/2` — `defmacro`s. See the `Bond.Predicates` moduledoc for the
    precedence/associativity rules and the canonical example.

`__opaque__/1` and `__truthy__/1` in `Bond.Predicates` are infrastructure
called by Bond-generated code. They are *not* a direct-use API and are
excluded from hexdocs (`@doc false`). Their stability is guaranteed only
insofar as Bond's generated code depends on them — user code should not
call them directly.

## `Bond.Test`

Brought into ExUnit modules via `use Bond.Test`. Provides:

  * `assert_precondition_violation/2`
  * `assert_postcondition_violation/2`
  * `assert_check_violation/2`
  * `assert_invariant_violation/2`

Each accepts an expression and a keyword list of optional fields to verify on
the raised error struct (`:label`, `:module`, `:function`, etc.). The full
keyword shape is documented in the `Bond.Test` moduledoc.

## `Bond.PropertyTest`

Brought into ExUnit modules via `use Bond.PropertyTest`. Provides:

  * `contract_holds/2` — runs StreamData-generated input through a single
    function and asserts every call satisfies its contracts.
  * `invariants_hold/2` — runs random sequences of operations over a
    struct module and asserts the module's `@invariant`s (and any
    per-function contracts) hold across every reachable state.

Requires the optional `:stream_data` dependency in the consumer's `mix.exs`.

## Telemetry

Bond emits exactly one telemetry event:

  * **Event name:** `[:bond, :assertion, :failure]`.
  * **Measurements:** `%{}` (no numeric measurements; emitted purely for
    observation).
  * **Metadata:** map with keys `:kind` (`:precondition` | `:postcondition` |
    `:invariant` | `:check`), `:label`, `:module`, `:function` (`{name, arity}`
    tuple), `:expression` (string source), `:file`, `:line`, `:binding`
    (keyword list of variables in scope at the assertion site). For inherited
    contracts the metadata also carries `:source_behaviour` (the originating
    `Bond.Behaviour`) or `:source_protocol` and `:impl` (the originating
    `Bond.Protocol` and the resolved implementation module).

The event is published *before* the corresponding error struct is raised, so
telemetry handlers see every assertion failure even when an upstream
`rescue` swallows the exception.

## Error structs

All four are raised by Bond, all four are catchable, all four share the same
shape (defined by the internal `Bond.AssertionError` `__using__` macro):

  * `Bond.PreconditionError`
  * `Bond.PostconditionError`
  * `Bond.InvariantError`
  * `Bond.CheckError`

Public fields on every error struct:

  * `:label` — `t:Bond.assertion_label/0` (`atom() | binary() | nil`).
  * `:expression` — `t:Bond.assertion_expression/0` (the AST of the asserted
    expression).
  * `:file` — `Path.t()`.
  * `:line` — `integer()`.
  * `:module` — `module()`.
  * `:function` — `{name :: atom(), arity :: non_neg_integer()}` tuple.
  * `:binding` — `keyword()` of in-scope variables at the assertion site.
  * `:source_behaviour` — `module() | nil`. The behaviour an inherited contract
    came from (`Bond.Behaviour`), or `nil`.
  * `:source_protocol` — `module() | nil`. The protocol a contract was declared
    on (`Bond.Protocol`), or `nil`.
  * `:impl` — `module() | nil`. When `:source_protocol` is set, the
    implementation the failing call resolved to (or `nil` if unresolved).

The `Exception.message/1` format is rendered by `Bond.AssertionError.message/2`
and is human-readable — the exact text is *not* part of the public surface
(see the stability doc).

## Application config keys

All under the `:bond` application:

  * `:preconditions` — mode (`true | false | :purge`).
  * `:postconditions` — mode.
  * `:checks` — mode.
  * `:invariants` — mode.
  * `:overrides` — list of `{module() | Regex.t(), keyword()}` tuples.
    The keyword list uses the same per-kind keys above (`:preconditions`,
    `:postconditions`, `:checks`, `:invariants`, `:warn_skipped_invariants`).
    First exact-match module wins over regex matches; regex matches are
    tried in list order.
  * `:warn_skipped_invariants` — boolean (default `true`).

The contract-checking chain `preconditions ≤ postconditions ≤ invariants` is
enforced at compile time and at runtime. Compile-time: if a lower kind is
`:purge`, every higher kind must also be `:purge` (this raises a
`CompileError` with a specific diagnostic). Runtime: if a lower kind is
`false`, every higher kind is also skipped, and Bond logs a one-time
`Logger.warning` per process per `(higher, lower)` pair. `:checks` is
orthogonal to the chain.

## Types

Two public types referenced from public specs:

  * `t:Bond.assertion_label/0` — `binary() | atom()`.
  * `t:Bond.assertion_expression/0` — a quoted expression AST tuple
    (`{atom(), Macro.metadata(), list()}`).

An internal `assertion_kind` type also exists in `Bond` (`@typedoc false` —
the union `:precondition | :postcondition | :check | :invariant`), but it's
referenced only from internal-to-internal sites. Direct use is not supported.

## What is *not* part of the public surface

The following exist in Bond's source tree but are explicitly **not** covered
by the stability guarantees:

  * Every module under `Bond.Compiler.*` and `Bond.Runtime.*` (all marked
    `@moduledoc internal: true`, all filtered out of hexdocs). This includes
    the FSM, the lifted-defp shapes, every helper in `Bond.Compiler.Assertion`
    / `AnnotatedFunction` / `ClauseWrapper` / `Clauses` / `Invariants` /
    `OldExpression` / `ContractDocs`, and the entire `Bond.Runtime.Eval`
    surface. Direct use of any of these is unsupported and may break on a
    patch release.
  * The `__opaque__/1` and `__truthy__/1` helpers in `Bond.Predicates` —
    called by Bond-generated code, not by users. Their existence is stable
    insofar as the generated code relies on them, but the *interface
    contract* (what they accept, return, or do internally) is not.
  * The shape of compiled wrapper functions / lifted defps that Bond emits
    into the user's module. The names (`__bond_preconditions__<fun>__<arity>`,
    `__bond_postconditions__...`, `__bond_invariants__...`) are not stable.
  * The text of compile-error diagnostics raised by Bond's macros. These are
    user-facing prose that may be reworded for clarity; the **fact** of a
    diagnostic firing (e.g. "labelled @invariant 2-arg form is removed")
    is stable, but the exact wording is not.
  * The text of runtime error messages emitted by `Exception.message/1` on
    `Bond.PreconditionError` et al. The error **struct fields** are stable
    (see above); the rendered message is not.
  * Telemetry handler invocation order (Bond emits a single event; if
    multiple handlers are attached, the OTP-defined order applies — not
    Bond's concern).

If you need any of the above to remain stable for a use case, open an issue
describing the use case; we'll consider promoting the specific piece into the
public surface in a future minor.
