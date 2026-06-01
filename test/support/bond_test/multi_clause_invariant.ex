defmodule BondTest.MultiClauseInvariant do
  @moduledoc """
  Fixture for the rc.4 multi-clause pre-invariant fix (GitHub #22).

  Exercises a struct `@invariant` pre-check on a function whose clauses are
  *heterogeneous* — one clause binds a `%__MODULE__{}`, a sibling clause binds a
  non-struct (guarded) value. Because no contract references the parameter by
  name (an `@invariant` references `subject`), Bond generates a canonical name at
  that position and rewrites the struct head as a nested
  `bond_arg_0 = (%__MODULE__{} = _ctx)` match — the shape that broke struct
  detection (Bug 1) and, together with dropped guards (Bug 2), let a guardless
  catch-all clause shadow the struct clause.

  Violating structs are built with `struct/2` to bypass any constructor.
  """

  use Bond

  defstruct n: 0

  @invariant subject.n >= 0

  # Struct clause FIRST, guarded non-struct clause second.
  def first_struct(%__MODULE__{} = ctx), do: ctx.n
  def first_struct(key) when is_binary(key), do: {:binary, key}
end
