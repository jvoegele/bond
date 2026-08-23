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

    test "a module-level server invariant is not headed by a bare `nil`" do
      Coverage.record(info(1, %{kind: :state_invariant, function: nil}), true)

      report = Coverage.report()
      assert report =~ "(every callback)"
      refute report =~ "\n    nil\n"
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

  describe "table ownership (#104)" do
    setup do
      after_suite = Application.fetch_env!(:ex_unit, :after_suite)
      on_exit(fn -> Application.put_env(:ex_unit, :after_suite, after_suite) end)
      :ok
    end

    test "install_reporter/0 creates the table, so recorded evaluations outlive the recorder" do
      drop_table()

      owner = start_reporter_owner()
      record_from_short_lived_process(info(1), true)

      # Asserted from a process that is neither the owner nor the recorder. Before #104 the
      # recording process created — and so owned — the table, and took this row with it when it
      # finished; asserting from inside the recording process would pass either way.
      assert [%{assertion_id: 1, checked: 1, failed: 0}] = Coverage.entries()
      assert :ets.info(:ets.whereis(:bond_coverage), :owner) == owner
    end
  end

  # Coverage codegen is compile-time opt-in, and `coverage_enabled?/0` is read at macro-expansion
  # time — so a module that should record has to be *compiled* while `:coverage` is on. These
  # tests therefore compile their subjects from source inside the test rather than using a
  # `test/support` fixture, which Bond's own suite compiles with coverage off.
  defp compile_with_coverage(source) do
    original = Application.fetch_env(:bond, :coverage)
    Application.put_env(:bond, :coverage, true)

    try do
      Code.compile_string(source)
    after
      case original do
        {:ok, value} -> Application.put_env(:bond, :coverage, value)
        :error -> Application.delete_env(:bond, :coverage)
      end
    end
  end

  defp entries_for(module) do
    Coverage.entries() |> Enum.filter(&(&1.module == module))
  end

  defp coverage_scratch(_context) do
    on_exit(fn ->
      for {module, _} <- :code.all_loaded(),
          String.starts_with?(Atom.to_string(module), "Elixir.BondTest.CoverageScratch.") do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    :ok
  end

  # The coverage table is reachable only by name, so a test about its lifetime has to name it.
  defp drop_table do
    case :ets.whereis(:bond_coverage) do
      :undefined -> :ok
      _ref -> :ets.delete(:bond_coverage)
    end

    :ok
  end

  # Stands in for the process running `test/test_helper.exs`: it installs the reporter and then
  # stays alive for the rest of the test, as that process does for the rest of the suite.
  defp start_reporter_owner do
    parent = self()

    owner =
      spawn(fn ->
        Coverage.install_reporter()
        send(parent, :installed)

        receive do
          :stop -> :ok
        end
      end)

    receive do
      :installed -> :ok
    after
      1_000 -> flunk("the reporter owner never installed the reporter")
    end

    on_exit(fn -> send(owner, :stop) end)
    owner
  end

  defp record_from_short_lived_process(info, result) do
    {pid, ref} = spawn_monitor(fn -> Coverage.record(info, result) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
    after
      1_000 -> flunk("the recording process did not finish")
    end
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

  describe "recording through every emission path (#107)" do
    setup :coverage_scratch

    test "server state invariants are recorded, not merely checked" do
      [{module, _} | _] =
        compile_with_coverage("""
        defmodule BondTest.CoverageScratch.Counter do
          use GenServer
          use Bond.Server

          @state_invariant non_negative: state.count >= 0

          @impl true
          def init(n), do: {:ok, %{count: n}}

          @impl true
          def handle_call(:inc, _from, %{count: c} = s), do: {:reply, c + 1, %{s | count: c + 1}}
        end
        """)

      assert {:reply, 2, _} = module.handle_call(:inc, self(), %{count: 1})

      assert [%{kind: :state_invariant, label: :non_negative, checked: n}] =
               entries_for(module)

      assert n > 0
    end

    test "the where/whenever non-match branch is recorded for an ordinary @pre" do
      # `shape_mismatch_call/2` is built on `check_call/2`, so this branch went unrecorded for
      # *every* contract kind, not just servers.
      [{module, _} | _] =
        compile_with_coverage("""
        defmodule BondTest.CoverageScratch.Shaped do
          use Bond

          @pre where(%{score: score} = input, positive: score > 0)
          def rank(input), do: input.score
        end
        """)

      assert module.rank(%{score: 5}) == 5
      assert_raise Bond.PreconditionError, fn -> module.rank(%{no_score: true}) end

      shape = Enum.find(entries_for(module), &(&1.label == :shape))
      assert %{checked: 1, failed: 1} = shape
    end
  end

  describe "attribution across implementations (#108)" do
    setup :coverage_scratch

    test "each implementation of an inherited contract gets its own row" do
      # Bound from the compile result rather than named literally: these modules do not exist
      # until this line runs, so a literal call would warn as undefined at *this* file's compile
      # time.
      [{_strategy, _}, {abs_mod, _}, {wrong_mod, _}] =
        compile_with_coverage("""
        defmodule BondTest.CoverageScratch.Strategy do
          use Bond.Behaviour

          @post non_negative: result >= 0
          @callback score(integer()) :: integer()
        end

        defmodule BondTest.CoverageScratch.Abs do
          use Bond, behaviours: [BondTest.CoverageScratch.Strategy]

          @impl true
          def score(n), do: abs(n)
        end

        defmodule BondTest.CoverageScratch.Wrong do
          use Bond, behaviours: [BondTest.CoverageScratch.Strategy]

          @impl true
          def score(n), do: n
        end
        """)

      assert abs_mod.score(-3) == 3
      assert wrong_mod.score(4) == 4
      assert_raise Bond.PostconditionError, fn -> wrong_mod.score(-1) end

      # One `Bond.Compiler.Assertion` is shared by both implementers, so keyed on
      # `assertion_id` alone these collapsed into a single row attributed to whichever ran
      # first — seed-dependent, and it printed one module's failure against the other's name.
      assert [abs_entry] = entries_for(abs_mod)
      assert [wrong_entry] = entries_for(wrong_mod)

      assert abs_entry.assertion_id == wrong_entry.assertion_id
      assert abs_entry.label == :non_negative
      assert wrong_entry.label == :non_negative

      # The failure belongs to `Wrong`, and only to `Wrong`.
      assert abs_entry.failed == 0
      assert wrong_entry.failed == 1
    end

    test "an invariant woven into several functions is attributed per function" do
      [{module, _} | _] =
        compile_with_coverage("""
        defmodule BondTest.CoverageScratch.Bounded do
          use Bond

          defstruct n: 0

          @invariant non_negative: subject.n >= 0

          def bump(%__MODULE__{} = s), do: %{s | n: s.n + 1}
          def reset(%__MODULE__{} = s), do: %{s | n: 0}
        end
        """)

      struct = struct!(module, n: 1)
      module.bump(struct)
      module.reset(struct)

      functions = module |> entries_for() |> Enum.map(& &1.function) |> Enum.sort()

      assert functions == [bump: 1, reset: 1]
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
