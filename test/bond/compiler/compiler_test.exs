defmodule Bond.CompilerTest do
  @moduledoc """
  Tests for `Bond.Compiler` helpers, primarily `resolve_config/3`.
  """

  use ExUnit.Case

  alias Bond.Compiler

  describe "resolve_config/3" do
    @global [
      preconditions: true,
      postconditions: true,
      checks: true,
      invariants: true,
      overrides: []
    ]

    test "returns the global defaults when there are no overrides or use_opts" do
      assert Compiler.resolve_config(MyApp.X, [], @global) == %{
               preconditions: true,
               postconditions: true,
               checks: true,
               invariants: true,
               warn_skipped_invariants: true
             }
    end

    test "global non-default config is reflected in the result" do
      global = Keyword.put(@global, :invariants, :purge)
      assert Compiler.resolve_config(MyApp.X, [], global).invariants == :purge
    end

    test "use_opts override global" do
      assert Compiler.resolve_config(MyApp.X, [invariants: :purge], @global)
             |> Map.fetch!(:invariants) == :purge
    end

    test "use_opts override partially (other keys keep global)" do
      result = Compiler.resolve_config(MyApp.X, [invariants: :purge], @global)

      assert result == %{
               preconditions: true,
               postconditions: true,
               checks: true,
               invariants: :purge,
               warn_skipped_invariants: true
             }
    end

    test "use_opts can purge invariants for a specific module" do
      assert Compiler.resolve_config(MyApp.X, [invariants: :purge], @global)
             |> Map.fetch!(:invariants) == :purge
    end

    test "global :invariants is honoured" do
      global = Keyword.put(@global, :invariants, false)
      assert Compiler.resolve_config(MyApp.X, [], global).invariants == false
    end

    test "missing :invariants in global defaults to true" do
      global = Keyword.delete(@global, :invariants)
      assert Compiler.resolve_config(MyApp.X, [], global).invariants == true
    end

    test "exact module match in :overrides wins over global" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [invariants: :purge]}])
      assert Compiler.resolve_config(MyApp.X, [], global).invariants == :purge
    end

    test "exact module match does not apply to other modules" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [invariants: :purge]}])
      assert Compiler.resolve_config(MyApp.Y, [], global).invariants == true
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
          {~r/^MyApp\./, invariants: false},
          {MyApp.X, invariants: :purge}
        ])

      # MyApp.X gets the exact match :purge, not the regex false
      assert Compiler.resolve_config(MyApp.X, [], global).invariants == :purge
      # MyApp.Y only matches the regex
      assert Compiler.resolve_config(MyApp.Y, [], global).invariants == false
    end

    test "first regex match wins when multiple regexes match" do
      global =
        Keyword.put(@global, :overrides, [
          {~r/^MyApp\.Workers\./, invariants: :purge},
          {~r/^MyApp\./, invariants: false}
        ])

      # Both patterns match MyApp.Workers.X; the first one in list order wins.
      assert Compiler.resolve_config(MyApp.Workers.X, [], global).invariants == :purge
    end

    test "use_opts override :overrides" do
      global = Keyword.put(@global, :overrides, [{MyApp.X, [invariants: false]}])

      assert Compiler.resolve_config(MyApp.X, [invariants: :purge], global).invariants ==
               :purge
    end

    test ":purge value is accepted in all positions" do
      global = [
        preconditions: :purge,
        postconditions: :purge,
        checks: :purge,
        invariants: :purge,
        overrides: []
      ]

      assert Compiler.resolve_config(MyApp.X, [], global) == %{
               preconditions: :purge,
               postconditions: :purge,
               checks: :purge,
               invariants: :purge,
               warn_skipped_invariants: true
             }
    end

    test "invalid mode values in use_opts are ignored, global is preserved" do
      # If a user passes a typo like `preconditions: "true"`, it's ignored rather than
      # silently breaking the contract emission.
      assert Compiler.resolve_config(MyApp.X, [preconditions: "true"], @global)
             |> Map.fetch!(:preconditions) == true
    end
  end

  describe "contract-chain validation" do
    @chain_global [
      preconditions: true,
      postconditions: true,
      checks: true,
      invariants: true,
      overrides: []
    ]

    test "valid: all in the BEAM" do
      assert %{} = Compiler.resolve_config(MyApp.X, [], @chain_global)
    end

    test "valid: progressively purge from the top down" do
      # invariants purged, preconditions/postconditions in
      assert %{} = Compiler.resolve_config(MyApp.X, [invariants: :purge], @chain_global)

      # postconditions+invariants purged, preconditions in
      assert %{} =
               Compiler.resolve_config(
                 MyApp.X,
                 [postconditions: :purge, invariants: :purge],
                 @chain_global
               )

      # everything in the chain purged
      assert %{} =
               Compiler.resolve_config(
                 MyApp.X,
                 [preconditions: :purge, postconditions: :purge, invariants: :purge],
                 @chain_global
               )
    end

    test "valid: false (runtime-disabled) for any kind doesn't violate the chain" do
      # false means compiled-in-but-runtime-off; that's fine even for lower kinds.
      assert %{} = Compiler.resolve_config(MyApp.X, [preconditions: false], @chain_global)
      assert %{} = Compiler.resolve_config(MyApp.X, [postconditions: false], @chain_global)
      assert %{} = Compiler.resolve_config(MyApp.X, [invariants: false], @chain_global)
    end

    test "invalid: postconditions in the BEAM with preconditions purged" do
      assert_raise CompileError, ~r/chain violated/s, fn ->
        Compiler.resolve_config(MyApp.X, [preconditions: :purge], @chain_global)
      end
    end

    test "invalid: invariants in the BEAM with postconditions purged" do
      assert_raise CompileError, ~r/chain violated/s, fn ->
        Compiler.resolve_config(MyApp.X, [postconditions: :purge], @chain_global)
      end
    end

    test ":checks is unconstrained — any combination is valid" do
      assert %{} = Compiler.resolve_config(MyApp.X, [checks: :purge], @chain_global)
      assert %{} = Compiler.resolve_config(MyApp.X, [checks: false], @chain_global)

      # :checks: :purge alongside everything-purged in the chain (chain rules don't touch it)
      assert %{} =
               Compiler.resolve_config(
                 MyApp.X,
                 [
                   preconditions: :purge,
                   postconditions: :purge,
                   invariants: :purge,
                   checks: :purge
                 ],
                 @chain_global
               )
    end
  end
end
