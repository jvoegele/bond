# Benchmark: compile-time overhead of `use Bond`
#
# Run with:   mix run bench/compile_overhead.exs
#
# Measures the wall-clock cost of compiling N modules with `use Bond` vs.
# N identical-shape modules without contracts. Approach:
#
#   * Generate 2N source strings on the fly: half use Bond + a few @pre/@post,
#     half are plain `def`s with the same arity and body.
#   * Compile each batch via `Code.compile_string/1` in the parent VM —
#     measures pure compile cost (macro expansion + Bond's FSM + BEAM
#     compile) without spawning child `mix` processes and their VM
#     startup overhead.
#   * REPEATS times for each batch; module names are namespaced per repeat
#     so redefinition warnings (and purge overhead) don't enter the
#     measurement.
#   * Report median, min, max in ms.

defmodule CompileBench do
  @n_modules 200
  @repeats 5
  @warmup_runs 2

  def run do
    IO.puts("Bond compile-time overhead — #{@n_modules} modules per run, " <>
      "#{@repeats} repeats (after #{@warmup_runs} warmup runs), median reported\n")

    # Warmup runs use a negative-namespace ("w" prefix) so they don't collide
    # with measurement runs (which use numeric run_ids). Warmup timings are
    # discarded.
    Enum.each(1..@warmup_runs, fn run ->
      compile_batch(generate_baseline("w#{run}"))
      compile_batch(generate_with_bond("w#{run}"))
    end)

    baseline_times =
      for run <- 1..@repeats do
        time_ms(fn -> compile_batch(generate_baseline("#{run}")) end)
      end

    bond_times =
      for run <- 1..@repeats do
        time_ms(fn -> compile_batch(generate_with_bond("#{run}")) end)
      end

    report("Baseline (no Bond)", baseline_times)
    report("With Bond (every module uses Bond + @pre/@post)", bond_times)

    baseline_median = median(baseline_times)
    bond_median = median(bond_times)
    overhead = bond_median - baseline_median

    IO.puts("\nOverhead:")
    IO.puts("  Total:      #{format(overhead)} ms over #{@n_modules} modules")
    IO.puts("  Per module: #{format(overhead / @n_modules)} ms")
    IO.puts("  Ratio:      #{Float.round(bond_median / baseline_median, 2)}× baseline")
  end

  # Generates N module source strings with namespaced names so each repeat
  # compiles a fresh module set (no redefinition / purge cost in the measure).
  defp generate_with_bond(run_id) do
    for i <- 1..@n_modules do
      """
      defmodule CompileBench.Bond_r#{run_id}_m#{i} do
        use Bond

        @pre is_integer(x) and x >= 0
        @post is_integer(result)
        def f(x), do: x + #{i}

        @pre is_integer(y)
        @post is_integer(result)
        def g(y), do: y * 2

        @pre is_binary(s)
        @post is_binary(result)
        def h(s), do: s <> "_#{i}"
      end
      """
    end
  end

  defp generate_baseline(run_id) do
    for i <- 1..@n_modules do
      """
      defmodule CompileBench.Plain_r#{run_id}_m#{i} do
        def f(x), do: x + #{i}
        def g(y), do: y * 2
        def h(s), do: s <> "_#{i}"
      end
      """
    end
  end

  defp compile_batch(sources) do
    Enum.each(sources, &Code.compile_string/1)
  end

  defp time_ms(fun) do
    {micros, _} = :timer.tc(fun)
    micros / 1000
  end

  defp report(label, times) do
    sorted = Enum.sort(times)
    med = Enum.at(sorted, div(@repeats, 2))
    {min, max} = {List.first(sorted), List.last(sorted)}

    IO.puts("  #{String.pad_trailing(label, 48)} " <>
      "#{format(med)} ms  (min #{format(min)}, max #{format(max)})")
  end

  defp median(list), do: Enum.sort(list) |> Enum.at(div(length(list), 2))
  defp format(ms), do: Float.round(ms, 0) |> trunc() |> Integer.to_string() |> String.pad_leading(5)
end

CompileBench.run()
