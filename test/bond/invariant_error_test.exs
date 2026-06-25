defmodule Bond.InvariantErrorTest do
  use ExUnit.Case, async: true

  alias Bond.InvariantError

  defp info(kind, extra) do
    Map.merge(
      %{
        kind: kind,
        label: :non_negative,
        expression: "state.count >= 0",
        file: "lib/counter.ex",
        line: 12,
        module: Counter,
        binding: [state: %{count: -1}]
      },
      extra
    )
  end

  test "the :kind field drives the headline; one struct covers all three invariant flavours" do
    struct_inv =
      InvariantError.exception(info(:invariant, %{function: {:size, 1}, binding: [subject: %{}]}))

    state_inv = InvariantError.exception(info(:state_invariant, %{function: {:handle_call, 3}}))

    transition_inv =
      InvariantError.exception(
        info(:transition_invariant, %{
          function: {:handle_cast, 2},
          expression: "new_state.count >= old_state.count",
          binding: [new_state: %{count: 0}, old_state: %{count: 5}]
        })
      )

    assert is_exception(struct_inv, InvariantError)
    assert Exception.message(struct_inv) =~ "invariant violated around Counter.size/1"
    assert Exception.message(state_inv) =~ "state invariant violated after Counter.handle_call/3"

    assert Exception.message(transition_inv) =~
             "transition invariant violated across Counter.handle_cast/2"
  end

  test "carries the kind as a field for filtering/assertions" do
    error = InvariantError.exception(info(:transition_invariant, %{function: {:handle_cast, 2}}))
    assert %InvariantError{kind: :transition_invariant, label: :non_negative} = error
  end

  test "the message still renders label and assertion" do
    message =
      InvariantError.exception(info(:state_invariant, %{function: {:handle_call, 3}}))
      |> Exception.message()

    assert message =~ "label: :non_negative"
    assert message =~ "assertion: state.count >= 0"
  end
end
