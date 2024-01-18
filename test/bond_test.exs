defmodule BondTest do
  use ExUnit.Case
  doctest Bond

  test "greets the world" do
    assert Bond.hello() == :world
  end
end
