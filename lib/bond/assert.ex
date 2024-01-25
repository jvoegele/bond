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

  defp assert!(%Assertion{expression: expression} = assertion, exception_type, opts \\ []) do
    imports =
      for module <- [Bond.Predicates | List.wrap(opts[:import])] do
        quote do
          import unquote(module)
        end
      end

    quote generated: true do
      unquote_splicing(imports)

      value = unquote(expression)

      if value do
        value
      else
        raise unquote(exception_type),
          assertion: unquote(Macro.escape(assertion)),
          env: __ENV__,
          binding: binding()
      end
    end
  end
end
