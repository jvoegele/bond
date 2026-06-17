# Dialyzer warnings intentionally ignored. Keep this list as small as possible — every entry
# is a place where Dialyzer is correct but the warning is unavoidable or intended.
#
# `lib/bond/predicates.ex` / `:no_return`:
#   The quantifier arity-guard macros (`forall/3`, `forall/4`, `exists/3`, `exists/4`) exist
#   only to fail compilation with a clear message when a `for`-style multi-generator/filter
#   form is used. Each clause unconditionally raises, so Dialyzer reports the generated
#   `MACRO-forall`/`MACRO-exists` functions as having "no local return" — which is true and
#   intended. Elixir does not permit an inline `@dialyzer` attribute on a macro
#   ("only functions are supported"), so the suppression lives here. This is the only source
#   of `:no_return` warnings in `predicates.ex`; a genuine no_return regression in any other
#   function of that module would still surface as a different file/warning.
[
  {"lib/bond/predicates.ex", :no_return}
]
