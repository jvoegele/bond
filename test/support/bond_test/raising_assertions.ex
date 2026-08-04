## Fixtures for Bond.AssertionEvaluationErrorTest (#77).
##
## Each module has a contract whose *expression* raises on some input, rather
## than returning truthy or falsy. `String.contains?(nil, "@")` is the shape from
## the issue: a perfectly ordinary predicate that is not total over its inputs.

defmodule BondTest.Raising.Precondition do
  @moduledoc false
  use Bond

  @pre valid: String.contains?(email, "@")
  def normalize(email), do: String.downcase(email)
end

defmodule BondTest.Raising.Postcondition do
  @moduledoc false
  use Bond

  @post nonempty: String.length(result) > 0
  def render(x), do: x
end

defmodule BondTest.Raising.Invariant do
  @moduledoc false
  use Bond

  defstruct [:attrs]

  # Partial for the same reason as the others: `map_size/1` raises on a non-map.
  @invariant nonempty: map_size(subject.attrs) > 0

  def touch(%__MODULE__{} = s), do: s
end

defmodule BondTest.Raising.Labelled do
  @moduledoc false
  use Bond

  # Unlabelled, to check the diagnostic still renders without a label.
  @pre String.contains?(email, "@")
  def normalize(email), do: email
end

defmodule BondTest.Raising.Sound do
  @moduledoc false
  use Bond

  # The documented fix: lead with a type check so the assertion is total.
  @pre valid: is_binary(email) and String.contains?(email, "@")
  def normalize(email), do: String.downcase(email)
end
