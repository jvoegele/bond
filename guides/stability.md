# Stability guarantees

From 1.0 onward, Bond commits to a Semantic Versioning contract over its
public API. This page states what that contract covers, what it explicitly
excludes, and the deprecation policy that governs changes inside the
guaranteed surface.

## The covered surface

The [Public API surface](public-api.md) page enumerates every callable,
attribute, telemetry event, error struct, configuration key, and type
covered by these guarantees. If a name appears there, you can depend on
it. If a name doesn't appear there, Bond reserves the right to change it
without a deprecation cycle.

In practical terms, the public surface is everything reachable through:

  * the eight modules published to hexdocs (verified by `mix docs`);
  * the `use Bond` macro and the attribute syntax it intercepts;
  * the `[:bond, :assertion, :failure]` telemetry event;
  * the four catchable error structs (`Bond.PreconditionError` et al.);
  * the `:bond` application-config keys, including `:overrides`;
  * the `@bond_warn_skipped_invariants` per-function module attribute.

## What stability *means*

For everything on the public surface:

  * **Patch (`X.Y.Z+1`)**: bug fixes, internal refactors, documentation
    improvements, and additions to internal modules. Public behaviour
    does not change in a way visible to correctly-written consumer code.
  * **Minor (`X.Y+1.0`)**: new additions to the public surface and new
    optional configuration. Existing names keep the same behaviour and
    accept the same arguments. Deprecations may be introduced here; they
    do not change behaviour, only emit a warning.
  * **Major (`X+1.0.0`)**: anything that's been deprecated for at least
    one minor release with a runtime or compile-time warning may be
    removed. Behaviour-changing modifications to the public surface
    happen here, or not at all.

Concrete examples of "covered":

  * `@pre is_binary(x)` will continue to be accepted syntax indefinitely.
  * The `:bond, :preconditions` config will keep accepting `true | false
    | :purge` with the documented semantics.
  * `Bond.PreconditionError` will keep exposing the fields listed in the
    [Public API page](public-api.md). New fields may be added in a minor;
    existing fields will not be removed or renamed without a deprecation
    cycle.
  * The `[:bond, :assertion, :failure]` telemetry event name and metadata
    field names are stable. New metadata fields may be added in a minor;
    existing fields will not be removed without a deprecation cycle.
  * Bond's contract-checking chain `preconditions ≤ postconditions ≤
    invariants` is part of the design and won't be loosened or removed.

## What stability *excludes*

The following are **not** covered, and may change in any release
including patch versions:

  * **Internal modules.** `Bond.Compiler.*` and `Bond.Runtime.*` are not
    published to hexdocs (filtered via `@moduledoc internal: true`).
    Their function names, signatures, and behaviours are implementation
    detail. Code that calls into either namespace is using a private API.
  * **The shape of generated code.** Bond rewrites contract-bearing
    functions into a `defoverridable` wrapper and a set of generated
    `defp __bond_*__` helpers. The names of those helpers
    (`__bond_preconditions__<fun>__<arity>` etc.), their argument shapes,
    and their internal structure are not stable. Don't pattern-match on
    them in stack traces or runtime introspection.
  * **The `__opaque__/1` and `__truthy__/1` helpers in `Bond.Predicates`.**
    These are called by Bond-generated code, not by users. Their existence
    is stable insofar as the generated code depends on them, but their
    interface contract is not.
  * **Compile-error diagnostic text.** Bond raises `CompileError` for a
    handful of misuses (legacy 2-arg `@invariant`, bare-plus-labelled
    `@pre`/`@post`, contract-chain violations). The *fact* of those
    errors firing is stable; the **prose** of the error messages may be
    rewritten for clarity. Don't pattern-match on the message text.
  * **`Exception.message/1` output on Bond error structs.** The error
    **struct fields** are stable (see the [Public API page](public-api.md));
    the rendered human-readable message format is not.
  * **The exact set of compile-time warnings Bond may emit.** New compile
    warnings may be added in any minor release if they catch genuine
    footguns. Bond ships these opt-out where possible (e.g.
    `:warn_skipped_invariants`) so consumers can suppress new warnings
    without holding off the upgrade.
  * **Telemetry handler invocation order.** Bond emits a single event;
    if you attach multiple handlers, OTP decides their invocation order,
    not Bond.

## Deprecation policy

Anything covered by the stability guarantees follows this policy when it
changes:

  1. **Minimum one minor release with a deprecation warning.** A
     deprecated function, macro, attribute, config key, or behaviour
     emits a runtime or compile-time warning naming the replacement.
     CHANGELOG entries for the minor release flag the deprecation under
     a "Deprecated" subsection.
  2. **Removal only in the next major.** After at least one minor cycle
     with the deprecation in place, the deprecated entity may be removed
     in the next `X+1.0.0`.
  3. **Behaviour changes** to existing entities are treated the same way
     as removals: deprecated in a minor (with a warning when the old
     behaviour is invoked), changed in the next major.

The version floor for the language/runtime (`elixir ~> X.Y` in `mix.exs`)
is not part of the per-feature stability surface. Bond may raise the
Elixir floor in a minor release; doing so will be called out in the
CHANGELOG's "Requirements" section.

## What to do if you depend on something that isn't covered

Open an issue describing the use case. We'll consider promoting the
specific piece into the public surface in a future minor — sometimes the
right answer is to expose a documented, stable API where there's currently
only an internal helper. Don't reach into internals silently; that leaves
us no signal to preserve what you depend on.
