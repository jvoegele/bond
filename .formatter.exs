# Used by "mix format"
#
# `contract_rules` is duplicated verbatim into `:locals_without_parens` (for
# bond's own source) and `:export.locals_without_parens` (for downstream
# projects that put `:bond` in their `:import_deps`). They MUST match: `@pre kw`
# parses as `@(pre(kw))`, and the formatter only drops the parens around the
# inner `pre(...)`/`post(...)`/`state_invariant(...)` call when that name is in
# the *formatting* project's `:locals_without_parens`. The `@`-prefix special
# case covers only the single-argument form, so a bare `@pre x: 1` formatted
# without a rule, but every multi-argument contract — `@post where(...), a, b`
# and every `@state_invariant`/`@invariant`/`@transition_invariant` — got
# re-parenthesised. `:*` (any arity) is required because the `where`/`whenever`
# form takes an arbitrary number of scoped assertions.
#
# Kept as a literal (not a local binding) so tools that read `.formatter.exs`
# structurally, without evaluating it, still see the rules.
[
  import_deps: [:stream_data],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [
    check: :*,
    old: 1,
    pre: :*,
    post: :*,
    invariant: :*,
    state_invariant: :*,
    transition_invariant: :*,
    @: 1,
    @: 2
  ],
  export: [
    locals_without_parens: [
      check: :*,
      old: 1,
      pre: :*,
      post: :*,
      invariant: :*,
      state_invariant: :*,
      transition_invariant: :*
    ]
  ]
]
