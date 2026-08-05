import Config

# The `purged` environment exists for CI (#79). Bond's own suite compiles in `:test`,
# where nothing is purged, so codegen that only misbehaves in a purging build — an
# attribute left without a reader, a variable left unused — is invisible to it. The
# downstream job compiles this app with `MIX_ENV=purged` and `--warnings-as-errors`,
# which is the shape a real adopter ships to production.
if config_env() == :purged do
  config :bond,
    preconditions: :purge,
    postconditions: :purge,
    invariants: :purge,
    checks: :purge
end
