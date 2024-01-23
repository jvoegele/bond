defmodule BondTest.Math do
  @moduledoc """
  Math module for testing Bond contracts.
  """

  use Bond

  require Logger

  @pre numeric_x: is_number(x), non_negative_x: x >= 0
  @post float_result: is_float(result),
        non_negative_result: result >= 0.0,
        "sqrt of 0 is 0": (x == 0) ~> (result === 0.0),
        "sqrt of 1 is 1": (x == 1) ~> (result === 1.0),
        "x > 1 implies result smaller than x": (x > 1) ~> (result < x)
  def sqrt(x, poison_pill \\ nil) do
    x2 = x * 2

    if is_function(poison_pill) do
      poison_pill.(x)
    else
      :math.sqrt(x)
    end
  rescue
    error ->
      Logger.error(error)
      reraise error, __STACKTRACE__
  end

  @pre numeric: is_number(x) and is_number(y)
  @post float_result: is_float(result)
  def pow(x, y) do
    check is_number(x)
    check y_is_number: is_number(y)
    check "x is number", is_number(x)
    check is_number(y), "y is number"
    x2 = x + y
    :math.pow(x, y)
  end
end
