defmodule BondTest.ConditionalCompilationTest do
  @moduledoc """
  End-to-end tests for `Application.compile_env(:bond, ...)`-driven contract emission.

  Each test sets the `:bond` application config, compiles a small fixture module via
  `defmodule` inline, and exercises it. `async: false` is required because the tests
  manipulate process-global application config.
  """

  use ExUnit.Case, async: false

  setup do
    on_exit(fn ->
      Application.delete_env(:bond, :preconditions)
      Application.delete_env(:bond, :postconditions)
      Application.delete_env(:bond, :checks)
    end)
  end

  test "preconditions disabled — no PreconditionError is raised" do
    Application.put_env(:bond, :preconditions, false)

    defmodule PreDisabled do
      use Bond

      @pre positive_x: x > 0
      def positive(x), do: x
    end

    # Would normally raise; with preconditions disabled at compile time, runs as-is.
    assert PreDisabled.positive(-1) == -1
  end

  test "postconditions disabled — no PostconditionError is raised" do
    Application.put_env(:bond, :postconditions, false)

    defmodule PostDisabled do
      use Bond

      @post never_zero: result != 0
      def maybe_zero(x), do: x
    end

    # Would normally raise on result == 0; with postconditions disabled, runs as-is.
    assert PostDisabled.maybe_zero(0) == 0
  end

  test "both disabled — no override is emitted (function runs as written)" do
    Application.put_env(:bond, :preconditions, false)
    Application.put_env(:bond, :postconditions, false)

    defmodule BothDisabled do
      use Bond

      @pre positive_x: x > 0
      @post non_zero: result != 0
      def identity(x), do: x
    end

    # Both raise paths are gone.
    assert BothDisabled.identity(-1) == -1
    assert BothDisabled.identity(0) == 0
  end

  test "checks disabled — check macro expands to :ok and does not evaluate the expression" do
    Application.put_env(:bond, :checks, false)

    parent = self()
    ref = make_ref()

    defmodule ChecksDisabled do
      use Bond

      # The check expression sends a message; it must NOT run when checks are disabled.
      # The args are silenced with leading underscores because the disabled `check` strips them.
      def f(_parent, _ref) do
        check send(_parent, {:check_ran, _ref}) == {:check_ran, _ref}
        :ok
      end
    end

    assert ChecksDisabled.f(parent, ref) == :ok
    refute_received {:check_ran, ^ref}
  end

  test "default config — preconditions and postconditions are evaluated" do
    # No put_env: defaults to true for everything.

    defmodule DefaultConfig do
      use Bond

      @pre positive_x: x > 0
      @post is_positive_result: result > 0
      def double(x), do: x * 2
    end

    assert DefaultConfig.double(5) == 10
    assert_raise Bond.PreconditionError, fn -> DefaultConfig.double(-1) end
  end
end
