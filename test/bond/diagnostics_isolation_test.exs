defmodule Bond.DiagnosticsIsolationTest do
  @moduledoc """
  Guards the property that #86 turned on: a test asserting a compile emitted *no*
  particular warning must not see warnings emitted by other tests compiling at the
  same time.

  `ExUnit.CaptureIO.capture_io(:stderr, …)` swaps the global stderr device, so it does
  see them — which is why `refute output =~ "unused"` in an `async: true` module failed
  in CI three times, each with a different unrelated module supplying the "unused".
  `BondTest.Diagnostics` uses `Code.with_diagnostics/1`, which is process-local.

  This test reproduces the race deliberately rather than waiting for CI to hit it.
  """

  use ExUnit.Case, async: true

  @noisy_modules 60

  describe "BondTest.Diagnostics.warnings/1" do
    test "does not pick up warnings from a concurrently compiling process" do
      parent = self()

      noisy =
        spawn(fn ->
          receive do: (:go -> :ok)

          for i <- 1..@noisy_modules do
            Code.compile_string("""
            defmodule Bond.DiagnosticsIsolationTest.Noisy#{i} do
              def f(unused_variable), do: :ok
            end
            """)
          end

          send(parent, :noise_done)
        end)

      send(noisy, :go)
      # Let the flood start before compiling the source under test, so the two overlap.
      Process.sleep(20)

      warning =
        BondTest.Diagnostics.warnings("""
        defmodule Bond.DiagnosticsIsolationTest.Quiet do
          def f(x), do: x
        end
        """)

      assert_receive :noise_done, 5_000

      refute warning =~ "unused",
             "captured a warning from another process: #{inspect(warning)}"
    end

    test "still reports the compiled source's own warnings" do
      warning =
        BondTest.Diagnostics.warnings("""
        defmodule Bond.DiagnosticsIsolationTest.OwnWarning do
          def f(unused_variable), do: :ok
        end
        """)

      assert warning =~ "unused"
    end
  end
end
