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
  ]
]
