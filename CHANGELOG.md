# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

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
- Removed modules: `Bond.Compiler.AnnotatedFunctionClause`,
  `Bond.Compiler.LegacyCompileStateFSM`,
  `Bond.Compiler.define_function_with_contract/4`.
- `Bond.Compiler.Assertion` now carries a stable random `:id` for use in
  error reporting and future internal tooling.

### Requirements

- Unchanged. Elixir `~> 1.14`.

## [0.8.3] - 2024-11-08

Released before this changelog was established. See the git history for
details.
