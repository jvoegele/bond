# Used by "mix format"
[
  import_deps: [:stream_data],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [
    check: 1,
    check: 2,
    old: 1,
    pre: 1,
    pre: 2,
    post: 1,
    post: 2,
    @: 1,
    @: 2
  ],
  # Exported to downstream projects that put `:bond` in their `:import_deps`.
  # `@pre`/`@post` are part of `@` syntax (handled by `Kernel.@/1`), so users
  # only need formatter rules for the bare `check` and `old` calls.
  export: [
    locals_without_parens: [
      check: 1,
      check: 2,
      old: 1
    ]
  ]
]
