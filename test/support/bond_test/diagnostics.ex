defmodule BondTest.Diagnostics do
  @moduledoc """
  Compile a source string and return only *its* diagnostics.

  Tests that assert a compile emits no particular warning cannot use
  `ExUnit.CaptureIO.capture_io(:stderr, …)`: that swaps the global stderr device, so
  every other test compiling concurrently writes into the captured string. In an
  `async: true` module a `refute output =~ "unused"` therefore fails whenever some
  unrelated fixture happens to emit an unused-variable or unused-import warning at the
  same moment — the flake in #86, which reached CI three times with a *different*
  polluting module each time.

  `Code.with_diagnostics/1` is process-local, so a concurrent compile in another
  process cannot contribute. Verified directly: with 60 warning-emitting modules
  compiling in a spawned process, `capture_io(:stderr, …)` picks their warnings up and
  `Code.with_diagnostics/1` does not.

  Prefer this over a stderr capture for any assertion about what a compile did or did
  not warn about.
  """

  @doc """
  Compiles `source` and returns the diagnostics it produced.

  Wrapped in `try/rescue` so a source that fails to compile still yields its
  diagnostics rather than aborting the test before they can be inspected.
  """
  @spec capture(String.t()) :: [map()]
  def capture(source) when is_binary(source) do
    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
        rescue
          CompileError -> :compile_error
        end
      end)

    diagnostics
  end

  @doc """
  The messages of every warning-severity diagnostic from compiling `source`, joined —
  a drop-in for what a stderr capture used to yield, minus everyone else's output.
  """
  @spec warnings(String.t()) :: String.t()
  def warnings(source) when is_binary(source) do
    source
    |> capture()
    |> Enum.filter(&(&1.severity == :warning))
    |> Enum.map_join("\n", & &1.message)
  end
end
