defmodule Bond.Runtime.Eval do
  @moduledoc internal: true
  @moduledoc """
  Internal helper module for runtime execution of contracts and assertions.
  """

  @assertion_errors %{
    precondition: Bond.PreconditionError,
    postcondition: Bond.PostconditionError,
    check: Bond.CheckError
  }

  def evaluate_preconditions(preconditions_fun) do
    evaluate_assertions(preconditions_fun)
  end

  def evaluate_postconditions(postconditions_fun) do
    evaluate_assertions(postconditions_fun)
  end

  def evaluate_checks(checks_fun) do
    evaluate_assertions(checks_fun)
  end

  defp evaluate_assertions(assertions_fun) do
    try do
      with_recursion_check(assertions_fun)
    catch
      {:assertion_failure, %{kind: kind} = assertion_info} ->
        exception = Map.fetch!(@assertion_errors, kind)
        raise exception, assertion_info
    end
  end

  defp with_recursion_check(assertions_fun) do
    # Mutually recursive contracts lead to infinite recursion, so don't evaluate assertions for a
    # function if other assertions are already being evaluated in the current process.
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
