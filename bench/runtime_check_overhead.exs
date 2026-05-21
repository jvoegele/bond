# Benchmark: runtime-check overhead for Bond contracts
#
# Run with:   mix run bench/runtime_check_overhead.exs
#
# Three fixture modules, each with the same trivial precondition (`is_number(x)`):
#
#   * `Purge`  — uses Bond with preconditions: :purge. No override; calls the original def.
#   * `True`   — uses Bond with preconditions: true (default).  Override + runtime guard.
#   * `False`  — uses Bond with preconditions: false.            Override + runtime guard,
#                                                                guard defaults to false.
#
# Each is called in a tight loop. We measure µs per call.

defmodule Bench.Purge do
  use Bond, preconditions: :purge, postconditions: :purge, checks: :purge

  @pre is_number(x)
  def f(x), do: x
end

defmodule Bench.True do
  use Bond, preconditions: true, postconditions: :purge, checks: :purge

  @pre is_number(x)
  def f(x), do: x
end

defmodule Bench.False do
  use Bond, preconditions: false, postconditions: :purge, checks: :purge

  @pre is_number(x)
  def f(x), do: x
end

# Warmup + measurement helpers ------------------------------------------------

defmodule Bench do
  def time(name, fun, iterations) do
    # Warmup
    Enum.each(1..1_000, fn _ -> fun.() end)

    {micros, _} = :timer.tc(fn -> for _ <- 1..iterations, do: fun.() end)
    ns_per_call = micros * 1_000 / iterations
    IO.puts("  #{String.pad_trailing(name, 30)} #{Float.round(ns_per_call, 1)} ns/call")
  end
end

iterations = 1_000_000

IO.puts("\nBond runtime-check overhead — #{iterations} iterations")
IO.puts("------------------------------------------------------")

Bench.time(":purge (no override)", fn -> Bench.Purge.f(42) end, iterations)
Bench.time("true (runtime get_env)", fn -> Bench.True.f(42) end, iterations)
Bench.time("false (runtime get_env)", fn -> Bench.False.f(42) end, iterations)

IO.puts("")
