## Fixtures for Bond.CanonicalNameCollisionTest.
##
## Each module has a multi-clause function where one clause destructures into a
## name that a sibling clause uses as its whole parameter. The canonical name for
## that position is therefore a name the destructuring clause already binds
## further down, which used to emit `def via(key = %{id: key})` and fail to
## compile with "the variable is defined in function of itself".
##
## Their existence as compiled fixtures is half the test; the companion test file
## asserts that dispatch, guards, and contracts all still mean what they say.

defmodule BondTest.NameCollision.MapDestructure do
  @moduledoc false
  use Bond

  # `key` here must mean the POSITIONAL argument. If it leaked to the inner
  # destructured value (an integer in the first clause), this would fail.
  @pre positional: is_map(key) or is_binary(key)
  def via(%{id: key}) when is_integer(key), do: {:from_map, key}
  def via(key) when is_binary(key), do: {:from_binary, key}
end

defmodule BondTest.NameCollision.TupleDestructure do
  @moduledoc false
  use Bond

  @pre positional: is_tuple(key) or is_binary(key)
  def via({:wrapped, key}), do: {:unwrapped, key}
  def via(key) when is_binary(key), do: {:bare, key}
end

defmodule BondTest.NameCollision.ListDestructure do
  @moduledoc false
  use Bond

  @pre positional: is_list(key) or is_binary(key)
  def via([key | _rest]), do: {:head, key}
  def via(key) when is_binary(key), do: {:bare, key}
end

defmodule BondTest.NameCollision.WithPostcondition do
  @moduledoc false
  use Bond

  # The postcondition must also see the positional argument. The first clause
  # destructures a *list* out of a map, so `is_map(key)` holds only if `key` is
  # the positional argument — were it the inner list, this would fail.
  @post positional: is_map(key) or is_integer(key)
  def size(%{entries: key}) when is_list(key), do: length(key)
  def size(key) when is_integer(key), do: key
end
