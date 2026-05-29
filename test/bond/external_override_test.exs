defmodule Bond.ExternalOverrideTest do
  @moduledoc """
  Verifies Bond tolerates externally-generated override clauses produced by the
  `defoverridable`-wrap pattern (the technique Norm's `@contract` and the `decorator` library
  use), independent of any specific third-party library.

  Fixture source: `test/support/bond_test/external_override.ex`.
  """

  use ExUnit.Case

  test "Bond's contract composes with an external defoverridable wrapper" do
    # Bond's @pre runs (outer), then the external wrapper adds 100 to the original `x * 2`.
    assert BondTest.ExternalOverride.wrapped(3) == 106
  end

  test "Bond's precondition still fires on the externally-wrapped function" do
    assert_raise Bond.PreconditionError, fn -> BondTest.ExternalOverride.wrapped(-1) end
  end
end
