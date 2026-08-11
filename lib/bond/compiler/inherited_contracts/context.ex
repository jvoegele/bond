defmodule Bond.Compiler.InheritedContracts.Context do
  @moduledoc internal: true
  @moduledoc """
  Captures the few axes on which behaviour-callback and protocol-function contract handling
  diverge, so `Bond.Compiler.InheritedContracts` can share everything else.

  A context is used in one of two roles, and only the first needs the whole struct:

    * **Accumulating** — `Bond.Behaviour`, `Bond.Protocol`, and `Bond.Protocol.Impl` stash pending
      `@pre`/`@post`/`@apply_contract` as they are encountered and flush them when the operation
      is declared. These set the `:pending_*` keys.
    * **Validating only** — `Bond.Compiler` (impl refinements, `@apply_contract` extensions) and
      `Bond.Compiler.NamedContracts` already hold their assertions and want nothing but
      `validate_referenced_names!/6`'s diagnostics. These leave the `:pending_*` keys `nil`.

  ## Diagnostic wording (both roles)

    * `:noun` — `"callback"` / `"function"` / `"contract"`; the word for a single argument in
      diagnostics.
    * `:contract_subject` — `"behaviour callback"` / `"protocol function"`; the phrase after
      "A contract on a …" in the unknown-reference message.
    * `:reference_scope` — `"the callback's named arguments"` / `"its named arguments"`; the
      phrase after "may reference only …".
    * `:arg_naming_hint?` — when `true`, the unknown-reference message appends the behaviour-only
      "Name the callback's arguments (e.g. …)" sentence.
    * `:reject_old` — when `true`, `old/1` in a `@pre`/`@post` is rejected at compile time (a
      protocol v1 non-goal; behaviours support `old/1`).

  ## Accumulation (accumulating role only)

    * `:pending_pre_key` / `:pending_post_key` — module-attribute keys under which pending
      `@pre`/`@post` are accumulated (each flavour uses its own keys).
    * `:pending_apply_key` — module-attribute key holding a pending `@apply_contract`, as
      `{ref, env}` or `nil`.
    * `:declaration_form` — `"@callback"` / "protocol \\`def\\`"; how the declaration the pending
      contracts attach to is named in diagnostics.
    * `:stamp_source_behaviour` — when `true`, each captured assertion is stamped with
      `source_behaviour: env.module` (behaviour inheritance attributes failures to the behaviour;
      protocols attribute via `source_protocol`/`impl` at the dispatch layer instead).
  """

  @enforce_keys [:noun, :contract_subject, :reference_scope]
  defstruct [
    :noun,
    :contract_subject,
    :reference_scope,
    :pending_pre_key,
    :pending_post_key,
    :pending_apply_key,
    :declaration_form,
    stamp_source_behaviour: false,
    reject_old: false,
    arg_naming_hint?: false
  ]

  @type t :: %__MODULE__{
          noun: String.t(),
          contract_subject: String.t(),
          reference_scope: String.t(),
          pending_pre_key: atom() | nil,
          pending_post_key: atom() | nil,
          pending_apply_key: atom() | nil,
          declaration_form: String.t() | nil,
          stamp_source_behaviour: boolean(),
          reject_old: boolean(),
          arg_naming_hint?: boolean()
        }
end
