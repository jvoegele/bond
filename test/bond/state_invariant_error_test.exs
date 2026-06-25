defmodule Bond.StateInvariantErrorTest do
  use ExUnit.Case, async: true

  alias Bond.StateInvariantError

  test "builds from an assertion-failure info map and renders a state-invariant message" do
    info = %{
      kind: :state_invariant,
      label: :non_negative,
      expression: "state.count >= 0",
      file: "lib/counter.ex",
      line: 12,
      module: Counter,
      function: {:handle_call, 3},
      binding: [state: %{count: -1}]
    }

    error = StateInvariantError.exception(info)

    assert is_exception(error, StateInvariantError)
    assert %StateInvariantError{label: :non_negative, expression: "state.count >= 0"} = error

    message = Exception.message(error)
    assert message =~ "state invariant violated after Counter.handle_call/3"
    assert message =~ "label: :non_negative"
    assert message =~ "assertion: state.count >= 0"
  end
end
