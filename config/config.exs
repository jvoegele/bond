import Config

if config_env() == :test do
  # Bond's own test fixtures deliberately use degenerate assertions (`1 == 1`, `1 + 1 == 2`, …)
  # as scaffolding for exercising the contract machinery, so the compile-time assertion linter
  # (#52) would flood the suite with (correct but unwanted) warnings — and fail it under
  # `--warnings-as-errors`. Silence it for the suite; tests that exercise the linter turn it back
  # on explicitly via `Application.put_env(:bond, :lint_assertions, true)`.
  config :bond, lint_assertions: false
end
