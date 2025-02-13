defmodule Bond.Runtime.Eval do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for runtime execution of contracts and assertions.
  """

  def evaluate_assertions(assertions_fun) do
    assertions_fun.()
  end
end
