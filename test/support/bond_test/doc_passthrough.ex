defmodule BondTest.DocPassthrough do
  @moduledoc "Fixture: `@doc` must survive whether or not Bond generates an override (#71)."
  use Bond

  @unit "widgets"

  @doc "Doc-only, uncontracted."
  def doc_only(x), do: x

  @doc "Contracted."
  @pre pos: y > 0
  def contracted(y), do: y

  @doc "Doc-only, following a contracted function."
  def doc_only_after(z), do: z

  @doc "Multi-clause with a guard."
  @pre pos: n > 0
  def multi(n) when is_integer(n), do: n
  def multi(n), do: n

  @doc "Default arguments."
  @pre pos: a > 0
  def defaults(a, b \\ 2), do: {a, b}

  @doc """
  Interpolated #{@unit}, contracted.
  """
  @pre pos: i > 0
  def interpolated(i), do: i

  def undocumented_contracted(x), do: x
  @pre pos: x > 0
  def undocumented(x), do: x

  @doc "An assertion long enough that `Macro.to_string/1` wraps it (#109)."
  @pre wrapping:
         is_binary(token) and byte_size(token) > 10 and String.starts_with?(token, "tok_") and
           token != "tok_"
  def wrapping(token), do: token
end

defmodule BondTest.DocPassthroughPurged do
  @moduledoc "Fixture: docs must survive `:purge`, which emits no override at all (#71)."
  use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge

  @doc "Contracted, but every kind is purged."
  @pre pos: x > 0
  def f(x), do: x
end

defmodule BondTest.DocPassthroughNoAtAnnotations do
  @moduledoc "Fixture: with the `@` override off, Bond must not touch documentation (#71)."
  use Bond, at_annotations: false

  @doc "User prose Bond must not overwrite."
  Bond.pre(pos: x > 0)
  def b(x), do: x
end
