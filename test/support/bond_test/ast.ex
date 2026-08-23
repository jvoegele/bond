defmodule BondTest.AST do
  @moduledoc """
  AST helpers for the compiler unit tests.

  Bond's compiler receives clause heads, guards, and bodies that the Elixir compiler parsed
  from **source**, where every variable carries the `nil` hygiene context. A test that builds
  the same shapes with `quote/2` gets variables stamped with the *test module's* context
  instead — a difference the compiler is sensitive to (#105), so a fixture that ignores it is
  testing a shape no real module produces.
  """

  @doc """
  Rewrites every variable in `ast` to the `nil` hygiene context, so a `quote/2`-built fixture
  models what the compiler actually hands Bond.

  Only variables are touched: a variable is `{name, meta, context}` with an atom context,
  which is what distinguishes it from a call, `{name, meta, args}`.
  """
  @spec as_source(Macro.t()) :: Macro.t()
  def as_source(ast) do
    Macro.prewalk(ast, fn
      {name, meta, context} when is_atom(name) and is_atom(context) and context != nil ->
        {name, meta, nil}

      other ->
        other
    end)
  end
end
