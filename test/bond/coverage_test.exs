defmodule Bond.CoverageTest do
  @moduledoc """
  Tests for contract coverage (#56): the `Bond.Coverage` store/report, the coverage-recording
  `Bond.Runtime.Eval` wrappers, and the compile-time codegen gating that emits them only when
  `config :bond, coverage: true`.

  `async: false` — these share the process-global ETS table and mutate `:bond` application env.
  """

  use ExUnit.Case, async: false

  alias Bond.Compiler.Assertion
  alias Bond.Coverage
  alias Bond.Runtime.Eval

  setup do
    Coverage.reset()
    :ok
  end

  defp info(id, overrides \\ %{}) do
    Map.merge(
      %{
        assertion_id: id,
        kind: :pre,
        label: :positive,
        expression: "x > 0",
        module: MyMod,
        function: {:f, 1},
        file: "a.ex",
        line: 3
      },
      overrides
    )
  end

  describe "record/2 and entries/0" do
    test "counts every evaluation and classifies falsy results as failures" do
      for _ <- 1..5, do: Coverage.record(info(1), true)
      Coverage.record(info(1), false)
      Coverage.record(info(1), nil)

      assert [%{checked: 7, failed: 2, label: :positive}] = Coverage.entries()
    end

    test "a truthy non-boolean result counts as a pass, not a failure" do
      Coverage.record(info(1), :ok)
      Coverage.record(info(1), 42)

      assert [%{checked: 2, failed: 0}] = Coverage.entries()
    end

    test "keeps each assertion_id separate and preserves its metadata" do
      Coverage.record(info(1), true)
      Coverage.record(info(2, %{label: :other, kind: :post}), false)

      entries = Coverage.entries()
      assert length(entries) == 2
      assert Enum.find(entries, &(&1.assertion_id == 2)).kind == :post
    end

    test "entries/0 is empty before anything is recorded" do
      assert Coverage.entries() == []
    end
  end

  describe "report/0" do
    test "flags a checked-but-never-failed assertion" do
      for _ <- 1..3, do: Coverage.record(info(1, %{label: :never_fails}), true)

      report = Coverage.report()
      assert report =~ "MyMod"
      assert report =~ "f/1"
      assert report =~ "@pre :never_fails"
      assert report =~ "⚠ never failed"
    end

    test "marks an assertion that has failed with the exercised marker" do
      Coverage.record(info(1), true)
      Coverage.record(info(1), false)

      report = Coverage.report()
      assert report =~ "✓"
      refute report =~ "⚠ never failed"
    end

    test "reports emptiness when nothing was evaluated" do
      assert Coverage.report() =~ "no contracts were evaluated"
    end
  end

  test "reset/0 clears accumulated coverage" do
    Coverage.record(info(1), true)
    assert Coverage.entries() != []

    assert Coverage.reset() == :ok
    assert Coverage.entries() == []
  end

  describe "Eval coverage wrappers" do
    test "check_assertion_covered records a pass and returns :ok" do
      assert Eval.check_assertion_covered(true, info(1), fn -> [] end) == :ok
      assert [%{checked: 1, failed: 0}] = Coverage.entries()
    end

    test "check_assertion_covered records a failure and still throws the failure" do
      assert {:assertion_failure, _info} =
               catch_throw(Eval.check_assertion_covered(false, info(1), fn -> [] end))

      assert [%{checked: 1, failed: 1}] = Coverage.entries()
    end

    test "check_value_covered records and returns the checked value on success" do
      assert Eval.check_value_covered(:the_value, info(1), fn -> [] end) == :the_value
      assert [%{checked: 1, failed: 0}] = Coverage.entries()
    end
  end

  describe "compile-time codegen gating" do
    setup do
      original = Application.fetch_env(:bond, :coverage)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:bond, :coverage, value)
          :error -> Application.delete_env(:bond, :coverage)
        end
      end)

      :ok
    end

    defp emitted_body do
      assertion = Assertion.new(:pre, :positive, quote(do: x > 0), __ENV__)
      Assertion.assertions_body([assertion], {:f, 1}) |> Macro.to_string()
    end

    test "emits the plain check_assertion when coverage is off (default)" do
      Application.put_env(:bond, :coverage, false)
      body = emitted_body()

      assert body =~ "check_assertion("
      refute body =~ "check_assertion_covered"
    end

    test "emits check_assertion_covered when coverage is enabled" do
      Application.put_env(:bond, :coverage, true)
      assert emitted_body() =~ "check_assertion_covered"
    end
  end
end
