defmodule Bond.Env do
  @moduledoc internal: true
  @moduledoc """
  Subset of `Macro.Env` struct that excludes fields that, according to the documentation, "are
  private to Elixir's macro expansion mechanism".
  """

  defstruct [:context, :context_modules, :file, :function, :line, :module]

  def new(%Macro.Env{} = env \\ __ENV__) do
    struct(__MODULE__, Map.from_struct(env))
  end
end
