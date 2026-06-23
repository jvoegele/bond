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

  describe "__bond_boundaries__/0 reflection (#36)" do
    defmodule WithBoundaries do
      use Bond

      @pre amount >= 0
      @pre amount <= 1000
      def deposit(account, amount), do: %{account | balance: account.balance + amount}

      @pre is_binary(name)
      def greet(name), do: "hi #{name}"

      def plain(x), do: x
    end

    defmodule NoBoundaries do
      use Bond

      @pre is_list(items)
      def first(items), do: hd(items)
    end

    test "emits a table mapping {fun, arity} to per-arg-index boundary candidates" do
      assert WithBoundaries.__bond_boundaries__() == %{
               {:deposit, 2} => %{1 => [-1, 0, 1, 999, 1000, 1001]}
             }
    end

    test "excludes functions whose preconditions have no literal boundary, and uncontracted ones" do
      table = WithBoundaries.__bond_boundaries__()
      refute Map.has_key?(table, {:greet, 1})
      refute Map.has_key?(table, {:plain, 1})
    end

    test "emits no reflection for a module with no literal precondition boundaries" do
      refute function_exported?(NoBoundaries, :__bond_boundaries__, 0)
    end
  end

  describe "__bond_precondition__/3 filter shim (#36)" do
    defmodule WithFilter do
      use Bond

      @pre amount >= 0
      @pre amount <= 1000
      def deposit(account, amount), do: %{account | balance: account.balance + amount}

      def plain(x), do: x
    end

    defmodule NoFilter do
      use Bond
      def passthrough(x), do: x
    end

    test "returns true for inputs that satisfy every precondition, including the boundary" do
      assert WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, 500])
      assert WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, 0])
      assert WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, 1000])
    end

    test "returns false (without raising) for inputs that violate a precondition" do
      refute WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, -1])
      refute WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, 1001])
    end

    test "a precondition violation does not emit a failure telemetry event" do
      handler = "filter-shim-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:bond, :assertion, :failure],
        fn _event, _measure, meta, pid -> send(pid, {:bond_failure, meta.kind}) end,
        self()
      )

      try do
        refute WithFilter.__bond_precondition__(:deposit, 2, [%{balance: 0}, -1])
        refute_receive {:bond_failure, _kind}, 50
      after
        :telemetry.detach(handler)
      end
    end

    test "the catch-all returns true for functions with no compiled precondition" do
      assert WithFilter.__bond_precondition__(:plain, 1, [42])
      assert WithFilter.__bond_precondition__(:totally_unknown, 3, [1, 2, 3])
    end

    test "a module with no compiled preconditions emits no shim at all" do
      # Like the boundaries reflection, an empty shim is omitted entirely. Callers
      # (`Bond.PropertyTest`) must guard with `function_exported?/3` and treat its absence as
      # "no precondition to filter" — equivalent to the catch-all's `true`.
      refute function_exported?(NoFilter, :__bond_precondition__, 3)
    end
  end
end
