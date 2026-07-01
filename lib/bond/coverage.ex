defmodule Bond.Coverage do
  @moduledoc """
  Contract coverage: a test-time diagnostic that surfaces assertions which are **checked but
  never observed to fail** (#56).

  The hardest contract bug to catch is the vacuous-but-passing assertion — one that runs at every
  call, always evaluates true, and so tells you nothing while looking like coverage. The
  compile-time assertion linter catches the *structurally* recognisable cases; this
  is the complementary *dynamic* signal: an assertion evaluated many times that has never once
  been false is a candidate for vacuity.

  > #### "Never failed" is a weak signal {: .info}
  >
  > A correct assertion over correct code, exercised by a passing suite, *also* never fails —
  > that is what a green suite means. So `⚠ never failed` is a **prompt**, not a verdict: either
  > write a test that makes the assertion fail (proving it *can* — see the
  > [Writing Sound Assertions](writing-sound-assertions.html) guide), or delete it. Coverage is an
  > opt-in diagnostic you run deliberately, never an always-on warning.

  ## Enabling

  Coverage instrumentation is **compile-time opt-in**, so a build that does not enable it is
  byte-for-byte unchanged and pays nothing. Turn it on for the test environment:

      # config/test.exs
      config :bond, coverage: true

  and print the report at the end of the suite by installing the reporter in `test/test_helper.exs`:

      ExUnit.start()
      Bond.Coverage.install_reporter()

  Then `mix test` prints a per-assertion table of how many times each contract was checked and how
  many of those were failures. Recording itself needs no reporter — `entries/0` and `report/0` can
  be read at any point.
  """

  @table :bond_coverage

  @typedoc """
  One assertion's accumulated coverage: its identifying metadata plus how many times it was
  `checked` and how many of those checks `failed`.
  """
  @type entry :: %{
          assertion_id: term(),
          kind: atom(),
          label: term(),
          expression: String.t() | nil,
          module: module() | nil,
          function: term(),
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          checked: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc """
  Records a single evaluation of the assertion described by `assertion_info` (the map the runtime
  check path already carries), classifying it as a failure when `result` is falsy.

  Called from the coverage-recording variants of the runtime check helpers, which the compiler
  emits only when coverage is enabled. Cheap and concurrency-safe: one `:ets.update_counter` keyed
  by the assertion's stable `:assertion_id`.
  """
  @spec record(map(), term()) :: :ok
  def record(%{assertion_id: id} = assertion_info, result) do
    ensure_table()
    failed = if result in [false, nil], do: 1, else: 0
    :ets.update_counter(@table, id, [{2, 1}, {3, failed}], {id, 0, 0, assertion_info})
    :ok
  end

  @doc """
  Returns the accumulated coverage as a list of `t:entry/0`, sorted by module, then line.
  """
  @spec entries() :: [entry()]
  def entries do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ref ->
        @table
        |> :ets.tab2list()
        |> Enum.map(&to_entry/1)
        |> Enum.sort_by(&{inspect(&1.module), &1.line || 0, &1.assertion_id})
    end
  end

  @doc """
  Clears all recorded coverage.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ref ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @doc """
  Renders the accumulated coverage as a human-readable table, grouped by module and function.
  Assertions that were checked at least once but never failed are flagged `⚠ never failed`.
  """
  @spec report() :: String.t()
  def report do
    case entries() do
      [] ->
        "Bond contract coverage: no contracts were evaluated.\n"

      entries ->
        body =
          entries
          |> Enum.group_by(& &1.module)
          |> Enum.sort_by(fn {module, _} -> inspect(module) end)
          |> Enum.map_join("\n", &format_module/1)

        "Bond contract coverage\n" <> body <> "\n"
    end
  end

  @doc """
  Installs an `ExUnit.after_suite/1` callback that prints `report/0` once the suite finishes. Call
  this in `test/test_helper.exs` after `ExUnit.start()`.
  """
  @spec install_reporter() :: :ok
  def install_reporter do
    ExUnit.after_suite(fn _result ->
      IO.puts("\n" <> report())
    end)

    :ok
  end

  # --- internals ------------------------------------------------------------------------------

  defp to_entry({id, checked, failed, info}) do
    %{
      assertion_id: id,
      kind: Map.get(info, :kind),
      label: Map.get(info, :label),
      expression: Map.get(info, :expression),
      module: Map.get(info, :module),
      function: Map.get(info, :function),
      file: Map.get(info, :file),
      line: Map.get(info, :line),
      checked: checked,
      failed: failed
    }
  end

  defp format_module({module, entries}) do
    functions =
      entries
      |> Enum.group_by(& &1.function)
      |> Enum.sort_by(fn {function, _} -> inspect(function) end)
      |> Enum.map_join("\n", &format_function/1)

    "  #{inspect(module)}\n" <> functions
  end

  defp format_function({function, entries}) do
    lines = Enum.map_join(entries, "\n", &format_entry/1)
    "    #{format_mfa(function)}\n" <> lines
  end

  defp format_entry(entry) do
    label = "@#{entry.kind} #{inspect(entry.label)}"
    marker = if entry.failed == 0, do: "⚠ never failed", else: "✓"

    "      #{String.pad_trailing(label, 34)} checked #{pad(entry.checked)}×  " <>
      "failed #{pad(entry.failed)}×  #{marker}"
  end

  defp format_mfa({name, arity}), do: "#{name}/#{arity}"
  defp format_mfa(other), do: inspect(other)

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 5)

  # Lazily create the shared coverage table. Race-safe: a concurrent creator that wins simply means
  # `:ets.new` here raises `ArgumentError`, by which point the table exists — which is all we need.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
        rescue
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end
end
