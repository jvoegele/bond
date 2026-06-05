# Benchmark: runtime-check overhead for Bond contracts
#
# Run with:   mix run bench/runtime_check_overhead.exs
#
# Measures the per-call wall-clock cost (ns/call) of every contract kind
# (@pre / @post / @invariant / check/1) in each of the three modes
# (true / false / :purge), plus a no-contracts baseline. Methodology:
#
#   * Each measurement uses :timer.tc over a tight `for _ <- 1..N, do: fun.()`
#     loop after a 1k-iteration warmup. We report nanoseconds per call.
#   * Each cell is run REPEATS times and we report the MEDIAN. Median is more
#     robust to GC pauses, scheduler pre-emption, and other transient spikes
#     than the mean. The min and max from the repeats are printed too so
#     readers can see the spread.
#   * `@pre`-only and `check/1`-only fixtures isolate those kinds with all
#     other kinds `:purge`d. `@post` and `@invariant` measurements include
#     lower kinds at `true` because Bond's contract chain
#     (preconditions ≤ postconditions ≤ invariants) requires lower kinds to
#     be compiled in when a higher kind is. Read those rows as marginal
#     cost of the higher kind ON TOP OF the lower kinds being on.

# -----------------------------------------------------------------------------
# Baseline (no Bond)
# -----------------------------------------------------------------------------

defmodule Bench.Baseline.Plain do
  def f(x), do: x
end

defmodule Bench.Baseline.Struct do
  defstruct [:value]
  def f(%__MODULE__{} = s), do: s
end

# -----------------------------------------------------------------------------
# @pre × {true, false, :purge}  — all other kinds purged
# -----------------------------------------------------------------------------

defmodule Bench.Pre.True do
  use Bond, preconditions: true, postconditions: :purge, checks: :purge, invariants: :purge
  @pre is_number(x)
  def f(x), do: x
end

defmodule Bench.Pre.False do
  use Bond, preconditions: false, postconditions: :purge, checks: :purge, invariants: :purge
  @pre is_number(x)
  def f(x), do: x
end

defmodule Bench.Pre.Purge do
  use Bond, preconditions: :purge, postconditions: :purge, checks: :purge, invariants: :purge
  @pre is_number(x)
  def f(x), do: x
end

# -----------------------------------------------------------------------------
# @post × {true, false, :purge}  — @pre on (chain requirement)
# Marginal cost of @post over @pre alone.
# -----------------------------------------------------------------------------

defmodule Bench.Post.True do
  use Bond, preconditions: true, postconditions: true, checks: :purge, invariants: :purge
  @pre is_number(x)
  @post is_number(result)
  def f(x), do: x
end

defmodule Bench.Post.False do
  use Bond, preconditions: true, postconditions: false, checks: :purge, invariants: :purge
  @pre is_number(x)
  @post is_number(result)
  def f(x), do: x
end

defmodule Bench.Post.Purge do
  use Bond, preconditions: true, postconditions: :purge, checks: :purge, invariants: :purge
  @pre is_number(x)
  @post is_number(result)
  def f(x), do: x
end

# -----------------------------------------------------------------------------
# @invariant × {true, false, :purge}  — @pre + @post on (chain requirement);
# invariant attaches to a struct method. Different shape from the pre/post
# fixtures above (the receiver is a struct), so the absolute numbers are not
# directly comparable across shapes.
# -----------------------------------------------------------------------------

defmodule Bench.Invariant.True do
  use Bond, preconditions: true, postconditions: true, checks: :purge, invariants: true
  defstruct [:value]
  @invariant subject.value > 0
  def f(%__MODULE__{} = s), do: s
end

defmodule Bench.Invariant.False do
  use Bond, preconditions: true, postconditions: true, checks: :purge, invariants: false
  defstruct [:value]
  @invariant subject.value > 0
  def f(%__MODULE__{} = s), do: s
end

defmodule Bench.Invariant.Purge do
  use Bond, preconditions: true, postconditions: true, checks: :purge, invariants: :purge
  defstruct [:value]
  @invariant subject.value > 0
  def f(%__MODULE__{} = s), do: s
end

# -----------------------------------------------------------------------------
# check/1 × {true, false, :purge}  — all other kinds purged. The check is
# inside the function body, not bound to the function head.
# -----------------------------------------------------------------------------

defmodule Bench.Check.True do
  use Bond, preconditions: :purge, postconditions: :purge, checks: true, invariants: :purge

  def f(x) do
    check(is_number(x))
    x
  end
end

defmodule Bench.Check.False do
  use Bond, preconditions: :purge, postconditions: :purge, checks: false, invariants: :purge

  def f(x) do
    check(is_number(x))
    x
  end
end

defmodule Bench.Check.Purge do
  use Bond, preconditions: :purge, postconditions: :purge, checks: :purge, invariants: :purge

  def f(x) do
    check(is_number(x))
    x
  end
end

# -----------------------------------------------------------------------------
# Wide-signature @pre + @post with old() — REAL generated code, the case the
# decomposition predicts benefits most. The lifted defps' `binding()` carries
# the full parameter list (+ result + olds): pre defp sees a..f (6 vars), post
# defp sees a..f + result + old(a) (8 vars). Each assertion references only a
# couple of them (pre: a; post: result, old(a)), so referenced-only trimming
# should drop ~5 and ~6 vars of per-call snapshot respectively.
# -----------------------------------------------------------------------------

defmodule Bench.PlainWide do
  def f(a, b, c, d, e, f), do: a + b + c + d + e + f
end

defmodule Bench.PostWide.True do
  use Bond, preconditions: true, postconditions: true, checks: :purge, invariants: :purge
  @pre is_integer(a)
  @post is_integer(result) and result >= old(a)
  def f(a, b, c, d, e, f), do: a + b + c + d + e + f
end

defmodule Bench.PostWide.Purge do
  use Bond, preconditions: :purge, postconditions: :purge, checks: :purge, invariants: :purge
  @pre is_integer(a)
  @post is_integer(result) and result >= old(a)
  def f(a, b, c, d, e, f), do: a + b + c + d + e + f
end

# -----------------------------------------------------------------------------
# Decomposition: what does the assertion-eval SUCCESS path actually cost?
#
# The real `@pre true` row above bundles: should_evaluate? (persistent_term) +
# closure alloc + evaluate_assertions (Process.get/put + try frame) + the lifted
# defp body, whose hot cost is `check_assertion(expr, info, binding())`. This
# section isolates the THIRD argument — the per-call `binding()` snapshot — which
# is built eagerly on every successful evaluation and discarded unless the
# assertion fails. All variants do identical surrounding work (10 locals + a
# tuple return, so `binding()` carries 11 entries); they differ ONLY in how the
# failure context is passed:
#
#   work       — baseline: the surrounding work, NO assertion call
#   eager_full — current Bond shape: eager binding() of the full scope
#   eager_ref  — eager, but only the assertion-referenced var: [x: x]
#   lazy_ref   — proposed: a 0-arity thunk capturing only x, invoked on failure
#   empty_bind — lower bound: assertion call with [] (no snapshot at all)
#
# Reads:  binding() cost  ≈ eager_full − eager_ref   (same call, list size differs)
#         thunk vs list   ≈ lazy_ref   − eager_ref
#         check/3 floor    ≈ empty_bind − work
# -----------------------------------------------------------------------------

defmodule Bench.Decomp do
  @moduledoc false

  # Synthetic analog of Bond.Runtime.Eval.check_assertion/3: multi-clause on
  # false/nil so the success clause ignores the third arg. On the (common)
  # success path the binding is pure waste — this is what we're measuring.
  def check(false, info, bind), do: throw({:assertion_failure, info, bind})
  def check(nil, info, bind), do: throw({:assertion_failure, info, bind})
  def check(_ok, _info, _bind), do: :ok

  # Lazy variant: the third arg is a 0-arity thunk, invoked only on failure.
  def check_lazy(false, info, fun), do: throw({:assertion_failure, info, fun.()})
  def check_lazy(nil, info, fun), do: throw({:assertion_failure, info, fun.()})
  def check_lazy(_ok, _info, _fun), do: :ok

  @info %{kind: :precondition, label: nil, expression: "is_number(x)", line: 1}

  def work(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end

  def eager_full(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    check(is_number(x), @info, binding())
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end

  def eager_ref(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    check(is_number(x), @info, x: x)
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end

  def lazy_ref(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    check_lazy(is_number(x), @info, fn -> [x: x] end)
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end

  def empty_bind(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    check(is_number(x), @info, [])
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end

  # Lazy FULL binding: preserves exact error semantics (the whole scope on
  # failure) but defers the snapshot into a thunk. The closure still captures
  # all 11 vars eagerly on the success path, so this measures "closure capture
  # of N" vs "eager list build of N".
  def lazy_full(x) do
    a1 = x + 1; a2 = x + 2; a3 = x + 3; a4 = x + 4; a5 = x + 5
    a6 = x + 6; a7 = x + 7; a8 = x + 8; a9 = x + 9; a10 = x + 10
    check_lazy(is_number(x), @info, fn -> binding() end)
    {a1, a2, a3, a4, a5, a6, a7, a8, a9, a10}
  end
end

# =============================================================================
# Measurement harness
# =============================================================================

defmodule Bench do
  @warmup 1_000
  @iterations 1_000_000
  @repeats 7

  def time(name, fun) do
    # Warmup
    Enum.each(1..@warmup, fn _ -> fun.() end)

    samples =
      for _ <- 1..@repeats do
        {micros, _} = :timer.tc(fn -> for _ <- 1..@iterations, do: fun.() end)
        micros * 1_000 / @iterations
      end

    sorted = Enum.sort(samples)
    median = Enum.at(sorted, div(@repeats, 2))
    min = List.first(sorted)
    max = List.last(sorted)

    IO.puts(
      "  #{String.pad_trailing(name, 28)} " <>
        "#{format(median)} ns/call  (min #{format(min)}, max #{format(max)})"
    )
  end

  defp format(ns), do: ns |> Float.round(1) |> Float.to_string() |> String.pad_leading(7)

  def section(label) do
    IO.puts("\n#{label}")
    IO.puts(String.duplicate("-", String.length(label)))
  end
end

# =============================================================================
# Driver
# =============================================================================

IO.puts("Bond runtime-check overhead — #{1_000_000} iterations × 7 repeats, median reported")
IO.puts("Reporting ns/call; lower is better; baseline subtracted in the doc.")

baseline_struct = struct!(Bench.Baseline.Struct, value: 1)
inv_true_struct = struct!(Bench.Invariant.True, value: 1)
inv_false_struct = struct!(Bench.Invariant.False, value: 1)
inv_purge_struct = struct!(Bench.Invariant.Purge, value: 1)

Bench.section("Baseline (no Bond)")
Bench.time("plain function", fn -> Bench.Baseline.Plain.f(42) end)
Bench.time("struct function", fn -> Bench.Baseline.Struct.f(baseline_struct) end)

Bench.section("@pre — pre-only fixture")
Bench.time(":purge", fn -> Bench.Pre.Purge.f(42) end)
Bench.time("true (enabled)", fn -> Bench.Pre.True.f(42) end)
Bench.time("false (runtime-disabled)", fn -> Bench.Pre.False.f(42) end)

Bench.section("@post — @pre at true, @post varying")
Bench.time(":purge", fn -> Bench.Post.Purge.f(42) end)
Bench.time("true (enabled)", fn -> Bench.Post.True.f(42) end)
Bench.time("false (runtime-disabled)", fn -> Bench.Post.False.f(42) end)

Bench.section("@invariant — @pre + @post at true, @invariant varying (struct fixture)")
Bench.time(":purge", fn -> Bench.Invariant.Purge.f(inv_purge_struct) end)
Bench.time("true (enabled)", fn -> Bench.Invariant.True.f(inv_true_struct) end)
Bench.time("false (runtime-disabled)", fn -> Bench.Invariant.False.f(inv_false_struct) end)

Bench.section("check/1 — check-only fixture")
Bench.time(":purge", fn -> Bench.Check.Purge.f(42) end)
Bench.time("true (enabled)", fn -> Bench.Check.True.f(42) end)
Bench.time("false (runtime-disabled)", fn -> Bench.Check.False.f(42) end)

Bench.section("@pre + @post wide signature (f/6) with old() — REAL generated code")
Bench.time("plain f/6 (no Bond)", fn -> Bench.PlainWide.f(1, 2, 3, 4, 5, 6) end)
Bench.time(":purge", fn -> Bench.PostWide.Purge.f(1, 2, 3, 4, 5, 6) end)
Bench.time("true (enabled)", fn -> Bench.PostWide.True.f(1, 2, 3, 4, 5, 6) end)

Bench.section("Decomposition — assertion-eval success path (11 vars in scope)")
Bench.time("work (no check call)", fn -> Bench.Decomp.work(42) end)
Bench.time("eager_full binding()", fn -> Bench.Decomp.eager_full(42) end)
Bench.time("eager_ref [x: x]", fn -> Bench.Decomp.eager_ref(42) end)
Bench.time("lazy_ref fn -> [x: x]", fn -> Bench.Decomp.lazy_ref(42) end)
Bench.time("lazy_full fn -> binding()", fn -> Bench.Decomp.lazy_full(42) end)
Bench.time("empty_bind []", fn -> Bench.Decomp.empty_bind(42) end)

IO.puts("")
