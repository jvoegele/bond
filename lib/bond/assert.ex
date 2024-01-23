defmodule Bond.Assert do
  @moduledoc internal: true
  @moduledoc """
  Provides assertion functions for evaluating contracts.
  """

  alias Bond.Assertion

  def require!(%Assertion{kind: :precondition} = precondition) do
    assert!(precondition, Bond.PreconditionError)
  end

  def ensure!(%Assertion{kind: :postcondition} = postcondition) do
    assert!(postcondition, Bond.PostconditionError)
  end

  def check!(%Assertion{kind: :check} = check) do
    assert!(check, Bond.CheckError)
  end

  defp assert!(%Assertion{expression: expression} = assertion, exception_type) do
    quote bind_quoted: [
            assertion: Macro.escape(assertion),
            expression: expression,
            exception_type: exception_type
          ],
          generated: true do
      import Bond.Predicates

      unless expression do
        raise exception_type,
          assertion: assertion,
          env: __ENV__,
          binding: binding()
      end
    end
  end
end
