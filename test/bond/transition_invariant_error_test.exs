defmodule Bond.TransitionInvariantErrorTest do
  use ExUnit.Case, async: true

  alias Bond.TransitionInvariantError

  test "builds from an assertion-failure info map and renders a transition-invariant message" do
    info = %{
      kind: :transition_invariant,
      label: :monotonic,
      expression: "new_state.count >= old_state.count",
      file: "lib/counter.ex",
      line: 12,
      module: Counter,
      function: {:handle_cast, 2},
      binding: [new_state: %{count: 0}, old_state: %{count: 5}]
    }

    error = TransitionInvariantError.exception(info)

    assert is_exception(error, TransitionInvariantError)

    assert %TransitionInvariantError{
             label: :monotonic,
             expression: "new_state.count >= old_state.count"
           } = error

    message = Exception.message(error)
    assert message =~ "transition invariant violated across Counter.handle_cast/2"
    assert message =~ "label: :monotonic"
    assert message =~ "assertion: new_state.count >= old_state.count"
  end
end
