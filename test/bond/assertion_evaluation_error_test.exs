defmodule Bond.AssertionEvaluationErrorTest do
  @moduledoc """
  Tests for #77: an assertion expression that *raises* must produce a Bond
  diagnostic, not a bare exception from inside the predicate.

  The failure mode this closes is asymmetric with the rest of the library.
  Everywhere else, turning contracts on can only add a `Bond.*Error` where the
  code would otherwise have proceeded. Here it could convert a call that would
  have worked — or returned a clean `{:error, _}` — into an unrelated crash, and
  purging made the crash disappear again.

  A raise is deliberately *not* treated as a violation: an assertion that raises
  has not been shown to hold or to fail, so conflating the two would mask genuine
  bugs in a predicate.
  """

  use ExUnit.Case, async: true

  alias Bond.AssertionEvaluationError
  alias BondTest.Raising

  def relay(_event, _measurements, metadata, pid), do: send(pid, {:failure, metadata})

  # The arguments below are deliberately wrong for the contract under test, which
  # Elixir's type checker flags on a direct call — correctly, and exactly as it
  # would for an uncontracted function. Passing them through the process
  # dictionary keeps the checker from narrowing them, without reaching for
  # `apply/3` (which Credo flags in turn when the arity is known).
  defp opaque(value), do: Process.get(:__bond_test_unset__, value)

  defp evaluation_error(fun) do
    fun.()
    flunk("expected a Bond.AssertionEvaluationError")
  rescue
    e in AssertionEvaluationError -> e
  end

  describe "a precondition whose expression raises" do
    test "raises a Bond diagnostic rather than the bare exception" do
      error = evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end)

      assert %AssertionEvaluationError{} = error
      assert error.kind == :precondition
      assert error.module == Raising.Precondition
      assert error.function == {:normalize, 1}
    end

    test "names the contract, the label, and the expression" do
      message =
        Exception.message(evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end))

      assert message =~ "precondition could not be evaluated"
      assert message =~ "Raising.Precondition.normalize/1"
      assert message =~ "label: :valid"
      assert message =~ "assertion: String.contains?(email, \"@\")"
    end

    test "carries the binding that produced the failure" do
      error = evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end)

      assert error.binding == [email: nil]
      assert Exception.message(error) =~ "binding: [email: nil]"
    end

    test "preserves the original exception and its stacktrace" do
      error = evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end)

      assert %FunctionClauseError{} = error.exception
      assert is_list(error.original_stacktrace)
      assert Exception.message(error) =~ "raised: ** (FunctionClauseError)"
      assert Exception.message(error) =~ "String.contains?/2"
    end

    test "the rescue variable does not leak into the binding" do
      # `binding()` is captured inside the compiler-emitted `rescue`, so Bond's own
      # variable is in scope there. Same principle as #78.
      error = evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end)

      refute Keyword.has_key?(error.binding, :bond_raised)
      refute Exception.message(error) =~ "bond_raised"
    end

    test "renders without a label when the assertion is unlabelled" do
      message =
        Exception.message(evaluation_error(fn -> Raising.Labelled.normalize(opaque(nil)) end))

      assert message =~ "precondition could not be evaluated"
      assert message =~ "raised: ** (FunctionClauseError)"
    end
  end

  describe "other contract kinds" do
    test "a postcondition whose expression raises" do
      error = evaluation_error(fn -> Raising.Postcondition.render(opaque(nil)) end)

      assert error.kind == :postcondition
      assert Exception.message(error) =~ "postcondition could not be evaluated in"
    end

    test "an invariant whose expression raises" do
      error =
        evaluation_error(fn ->
          Raising.Invariant.touch(%Raising.Invariant{attrs: opaque(:not_a_map)})
        end)

      assert error.kind == :invariant
      assert Exception.message(error) =~ "invariant could not be evaluated"
    end
  end

  describe "it is not a violation" do
    test "the error type is distinct from the violation types" do
      error = evaluation_error(fn -> Raising.Precondition.normalize(opaque(nil)) end)

      refute is_struct(error, Bond.PreconditionError)
      assert is_struct(error, AssertionEvaluationError)
    end

    test "rescuing PreconditionError does not catch it" do
      # Conflating the two would let a broken predicate masquerade as a contract
      # violation, which is the mistake option 2 in the issue would have made.
      assert_raise AssertionEvaluationError, fn ->
        try do
          Raising.Precondition.normalize(opaque(nil))
        rescue
          _ in Bond.PreconditionError -> flunk("should not have been caught as a violation")
        end
      end
    end
  end

  describe "the happy path is unaffected" do
    test "a passing contract still returns normally" do
      assert Raising.Precondition.normalize("A@B.com") == "a@b.com"
    end

    test "a genuine violation still raises the violation type" do
      assert_raise Bond.PreconditionError, fn ->
        Raising.Precondition.normalize(opaque("nope"))
      end
    end

    test "a total assertion handles the input the partial one could not" do
      # The documented fix from the guide: lead with a type check.
      assert_raise Bond.PreconditionError, fn -> Raising.Sound.normalize(opaque(nil)) end
    end
  end

  describe "telemetry" do
    setup do
      handler = "eval-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(handler, [:bond, :assertion, :failure], &__MODULE__.relay/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "emits on the same event, so existing handlers still see it" do
      assert_raise AssertionEvaluationError, fn ->
        Raising.Precondition.normalize(opaque(nil))
      end

      assert_receive {:failure, metadata}
      assert metadata.label == :valid
    end

    test "keeps :kind as the contract kind, so kind-based filters keep working" do
      assert_raise AssertionEvaluationError, fn ->
        Raising.Precondition.normalize(opaque(nil))
      end

      assert_receive {:failure, metadata}
      assert metadata.kind == :precondition
    end

    test "carries :exception, which is what distinguishes it from a violation" do
      assert_raise AssertionEvaluationError, fn ->
        Raising.Precondition.normalize(opaque(nil))
      end

      assert_receive {:failure, metadata}
      assert %FunctionClauseError{} = metadata.exception
    end

    test "an ordinary violation carries no :exception" do
      assert_raise Bond.PreconditionError, fn ->
        Raising.Precondition.normalize(opaque("nope"))
      end

      assert_receive {:failure, metadata}
      refute Map.get(metadata, :exception)
    end
  end
end
