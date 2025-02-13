defmodule Bond.Runtime.Eval do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for runtime execution of contracts and assertions.
  """

  def evaluate_assertions(assertions_fun) do
    with_recursion_check(assertions_fun)
  end

  defp with_recursion_check(assertions_fun) do
    # Mutually recursive contracts lead to infinite recursion, so don't evaluate assertions for a
    # function if they are already being evaluated for the original function call.
    #
    # Assertion Evaluation rule (from Object-Oriented Software Construction):
    # During the process of evaluating an assertion at run-time, routine calls shall
    # be executed without any evaluation of the associated assertions.
    if not evaluating_assertions?() do
      set_evaluating_assertions(true)

      try do
        assertions_fun.()
      after
        set_evaluating_assertions(false)
      end
    end
  end

  defp evaluating_assertions? do
    Process.get(:__bond_evaluating_assertions__, false)
  end

  defp set_evaluating_assertions(bool) do
    Process.put(:__bond_evaluating_assertions__, bool)
  end
end
