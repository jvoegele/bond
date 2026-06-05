defmodule Bond.Runtime.TelemetryTest do
  @moduledoc false

  use ExUnit.Case

  alias BondTest.Math
  alias BondTest.SubjectInvariantSmoke, as: Smoke

  defmodule CheckFixture do
    @moduledoc false
    use Bond

    def must_be_positive(n) do
      check positive_n: n > 0
      n
    end
  end

  @event [:bond, :assertion, :failure]

  # Module function instead of an anon fn so :telemetry doesn't warn about local handlers.
  def forward(name, measurements, metadata, pid) do
    send(pid, {:telemetry, name, measurements, metadata})
  end

  setup do
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(handler_id, @event, &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "[:bond, :assertion, :failure]" do
    test "fires on precondition violation with kind: :precondition metadata" do
      assert_raise Bond.PreconditionError, fn -> Math.sqrt(-1) end

      assert_receive {:telemetry, @event, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
      assert metadata.kind == :precondition
      assert metadata.module == BondTest.Math
      assert metadata.function == {:sqrt, 2}
      assert metadata.label == :non_negative_x
      assert metadata.expression == "x >= 0"
      assert is_binary(metadata.assertion_id)
      assert metadata.binding[:x] == -1
    end

    test "fires on postcondition violation with kind: :postcondition metadata" do
      assert_raise Bond.PostconditionError, fn ->
        Math.sqrt(2, fn _ -> 10 end)
      end

      assert_receive {:telemetry, @event, _measurements, metadata}
      assert metadata.kind == :postcondition
      assert metadata.module == BondTest.Math
      assert metadata.function == {:sqrt, 2}
      assert metadata.label == :float_result
    end

    test "fires on check violation with kind: :check metadata" do
      assert_raise Bond.CheckError, fn -> CheckFixture.must_be_positive(-1) end

      assert_receive {:telemetry, @event, _measurements, metadata}
      assert metadata.kind == :check
      assert metadata.module == Bond.Runtime.TelemetryTest.CheckFixture
      assert metadata.label == :positive_n
      assert is_binary(metadata.assertion_id)
    end

    test "fires on invariant violation with kind: :invariant metadata" do
      # SubjectInvariantSmoke has `@invariant size_within_capacity: length(subject.items)
      # <= subject.capacity`. Hand-construct an invalid struct that violates it, then
      # call a function whose head triggers the pre-invariant check.
      invalid = %Smoke{items: [:a, :b, :c], capacity: 1}

      assert_raise Bond.InvariantError, fn -> Smoke.push(invalid, :d) end

      assert_receive {:telemetry, @event, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
      assert metadata.kind == :invariant
      assert metadata.module == BondTest.SubjectInvariantSmoke
      assert metadata.function == {:push, 2}
      assert metadata.label == :size_within_capacity
      assert is_binary(metadata.assertion_id)
    end

    test "does not fire on successful precondition" do
      assert _ = Math.sqrt(4)
      refute_receive {:telemetry, @event, _, _}
    end

    test "does not fire on successful postcondition" do
      assert _ = Math.sqrt(4)
      refute_receive {:telemetry, @event, _, _}
    end

    test "does not fire when the runtime guard skips evaluation" do
      Bond.Config.disable(:preconditions)
      on_exit(fn -> Bond.Config.reset() end)

      # With preconditions runtime-disabled, sqrt(-1) no longer raises — but :math.sqrt(-1)
      # will. Catch that and confirm no telemetry event arrived from Bond.
      try do
        Math.sqrt(-1)
      rescue
        _ -> :ok
      end

      refute_receive {:telemetry, @event, _, _}
    end

    test "stable assertion_id makes the same assertion identifiable across failures" do
      assert_raise Bond.PreconditionError, fn -> Math.sqrt(-1) end
      assert_receive {:telemetry, @event, _, metadata1}

      assert_raise Bond.PreconditionError, fn -> Math.sqrt(-2) end
      assert_receive {:telemetry, @event, _, metadata2}

      assert metadata1.assertion_id == metadata2.assertion_id
    end
  end
end
