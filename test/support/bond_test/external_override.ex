defmodule BondTest.ExternalOverrideWrapper do
  @moduledoc """
  Minimal stand-in for any library that wraps functions via the `defoverridable` pattern
  (Norm's `@contract`, anything built on the `decorator` library, etc.). In `@before_compile`
  it makes `wrapped/1` overridable and redefines it to wrap the original via `super`.

  Used by `BondTest.ExternalOverride` to verify Bond tolerates externally-generated override
  clauses without depending on a specific third-party library.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile BondTest.ExternalOverrideWrapper
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable wrapped: 1

      def wrapped(x) do
        super(x) + 100
      end
    end
  end
end

defmodule BondTest.ExternalOverride do
  @moduledoc false

  # The wrapper is `use`d first so its `@before_compile` runs before Bond's: the override clause
  # it injects fires Bond's `@on_definition` (overridable, already-seen MFA) and is tolerated.
  use BondTest.ExternalOverrideWrapper
  use Bond

  @pre positive: x > 0
  def wrapped(x), do: x * 2
end
