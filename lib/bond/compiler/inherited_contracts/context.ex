defmodule Bond.Compiler.InheritedContracts.Context do
  @moduledoc internal: true
  @moduledoc """
  Captures the few axes on which behaviour-callback and protocol-function contract handling
  diverge, so `Bond.Compiler.InheritedContracts` can share everything else.

  Fields:

    * `:noun` — `"callback"` / `"function"`; the word for a single argument in diagnostics.
    * `:contract_subject` — `"behaviour callback"` / `"protocol function"`; the phrase after
      "A contract on a …" in the unknown-reference message.
    * `:reference_scope` — `"the callback's named arguments"` / `"its named arguments"`; the
      phrase after "may reference only …".
    * `:pending_pre_key` / `:pending_post_key` — module-attribute keys under which pending
      `@pre`/`@post` are accumulated (the two flavours use different keys).
    * `:stamp_source_behaviour` — when `true`, each captured assertion is stamped with
      `source_behaviour: env.module` (behaviour inheritance attributes failures to the behaviour;
      protocols attribute via `source_protocol`/`impl` at the dispatch layer instead).
    * `:reject_old` — when `true`, `old/1` in a `@post` is rejected at compile time (a protocol
      v1 non-goal; behaviours support `old/1`).
    * `:arg_naming_hint?` — when `true`, the unknown-reference message appends the behaviour-only
      "Name the callback's arguments (e.g. …)" sentence.
  """

  @enforce_keys [:noun, :contract_subject, :reference_scope, :pending_pre_key, :pending_post_key]
  defstruct [
    :noun,
    :contract_subject,
    :reference_scope,
    :pending_pre_key,
    :pending_post_key,
    stamp_source_behaviour: false,
    reject_old: false,
    arg_naming_hint?: false
  ]
end
