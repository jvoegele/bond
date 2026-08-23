defmodule BondTest.GeneratedHeads do
  @moduledoc """
  Fixture for #105: an invariant-bearing module whose public functions have clause heads
  built by a macro rather than written in source.

  `Ecto.Schema` emits its `__schema__/1,2` clauses by splicing quoted fragments into the
  head with `unquote_splicing/1`, so the variables in those heads carry the `quote`-
  introduced hygiene context (`Elixir`) instead of the module's (`nil`). Invariants weave
  into *every* public function of the declaring module, so they hit those heads — and the
  wrapper used to bind its canonical name in the head's own context while referencing it
  from the body in `nil`, which is a different variable. Every shape below failed to
  compile with `undefined variable "bond_arg_<idx>"` (or `"<user name>"`) before the fix.

  The clauses are deliberately built the way Ecto builds them — head *and* body from
  quoted data — rather than written literally, since a literal `_` in source carries the
  `nil` context and compiles fine either way.

  `warn_skipped_invariants: false` because most of these functions genuinely do not take
  or return the struct, which is the point: they are the generated accessors an invariant
  has nothing to say about, and the warning would be correct but is not what is under test.
  """

  use Bond, warn_skipped_invariants: false

  defstruct n: 0

  @invariant non_negative: subject.n >= 0

  def bump(%__MODULE__{} = s), do: %{s | n: s.n + 1}

  # A quote-generated wildcard at a position no clause names: the canonical is a generated
  # `bond_arg_<idx>`, which is the shape the issue reports first.
  for {args, body} <- [
        {[:fields, quote(do: _)], quote(do: [:n])},
        {[:source, quote(do: _)], quote(do: "generated_heads")}
      ] do
    def meta(unquote_splicing(args)), do: unquote(body)
  end

  # A quote-generated *named* variable, referenced from a quote-generated body. Here the
  # canonical name and the head's name agree, and only the context differs — the case that
  # failed with `undefined variable "kind"`.
  for {args, body} <- [
        {[quote(do: kind), :one], quote(do: {:one, kind})},
        {[quote(do: kind), :many], quote(do: {:many, kind})}
      ] do
    def tagged(unquote_splicing(args)), do: unquote(body)
  end

  # A generated head that *does* take the struct. The entry check must still fire through
  # it: making the module compile again is only half the fix if invariants go silent here.
  for {args, body} <- [{[quote(do: %__MODULE__{} = s)], quote(do: s.n)}] do
    def peek(unquote_splicing(args)), do: unquote(body)
  end

  # A generated head that destructures the struct under a binding, with a guard — the
  # combination that exercises guard-var survival alongside the context rewrite.
  for {args, guard, body} <- [
        {[quote(do: %__MODULE__{n: n} = s)], quote(do: n > 1), quote(do: s.n * 2)}
      ] do
    def doubled(unquote_splicing(args)) when unquote(guard), do: unquote(body)
  end

  def doubled(%__MODULE__{}), do: :too_small
end
