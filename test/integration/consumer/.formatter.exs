# Pulls in Bond's exported `locals_without_parens` (check/1, check/2, old/1)
# so `mix format` treats this consumer's contract calls correctly.
[
  import_deps: [:bond, :stream_data],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
