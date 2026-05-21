defmodule Bond.CompilerTest do
  @moduledoc """
  Tests for `Bond.Compiler` helpers, primarily `resolve_config/3`.
  """

  use ExUnit.Case

  alias Bond.Compiler

  describe "resolve_config/3" do
    @global [preconditions: true, postconditions: true, checks: true, overrides: []]

    test "returns the global defaults when there are no overrides or use_opts" do
      assert Compiler.resolve_config(MyApp.X, [], @global) == %{
               preconditions: true,
               postconditions: true,
               checks: true
             }
    end

    test "global non-default config is reflected in the result" do
      global = Keyword.put(@global, :preconditions, :purge)
      assert Compiler.resolve_config(MyApp.X, [], global).preconditions == :purge
    end

    test "use_opts override global" do
      assert Compiler.resolve_config(MyApp.X, [preconditions: :purge], @global)
             |> Map.fetch!(:preconditions) == :purge
    end

    test "use_opts override partially (other keys keep global)" do
      result = Compiler.resolve_config(MyApp.X, [preconditions: :purge], @global)

      assert result == %{
               preconditions: :purge,
               postconditions: true,
               checks: true
             }
    end

    test "exact module match in :overrides wins over global" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [preconditions: :purge]}])
      assert Compiler.resolve_config(MyApp.X, [], global).preconditions == :purge
    end

    test "exact module match does not apply to other modules" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [preconditions: :purge]}])
      assert Compiler.resolve_config(MyApp.Y, [], global).preconditions == true
    end

    test "regex pattern matches module names" do
      global =
        Keyword.put(@global, :overrides, [{~r/^MyApp\.Workers\./, [postconditions: false]}])

      assert Compiler.resolve_config(MyApp.Workers.Foo, [], global).postconditions == false
      assert Compiler.resolve_config(MyApp.Other, [], global).postconditions == true
    end

    test "exact match wins over regex even when regex appears first" do
      global =
        Keyword.put(@global, :overrides, [
          {~r/^MyApp\./, preconditions: false},
          {MyApp.X, preconditions: :purge}
        ])

      # MyApp.X gets the exact match :purge, not the regex false
      assert Compiler.resolve_config(MyApp.X, [], global).preconditions == :purge
      # MyApp.Y only matches the regex
      assert Compiler.resolve_config(MyApp.Y, [], global).preconditions == false
    end

    test "first regex match wins when multiple regexes match" do
      global =
        Keyword.put(@global, :overrides, [
          {~r/^MyApp\.Workers\./, preconditions: :purge},
          {~r/^MyApp\./, preconditions: false}
        ])

      # Both patterns match MyApp.Workers.X; the first one in list order wins.
      assert Compiler.resolve_config(MyApp.Workers.X, [], global).preconditions == :purge
    end

    test "use_opts override :overrides" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [preconditions: false]}])

      assert Compiler.resolve_config(MyApp.X, [preconditions: :purge], global).preconditions ==
               :purge
    end

    test ":purge value is accepted in all positions" do
      global = [
        preconditions: :purge,
        postconditions: :purge,
        checks: :purge,
        overrides: []
      ]

      assert Compiler.resolve_config(MyApp.X, [], global) == %{
               preconditions: :purge,
               postconditions: :purge,
               checks: :purge
             }
    end

    test "invalid mode values in use_opts are ignored, global is preserved" do
      # If a user passes a typo like `preconditions: "true"`, it's ignored rather than
      # silently breaking the contract emission.
      assert Compiler.resolve_config(MyApp.X, [preconditions: "true"], @global)
             |> Map.fetch!(:preconditions) == true
    end
  end
end
