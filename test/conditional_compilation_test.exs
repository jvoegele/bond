defmodule BondTest.ConditionalCompilationTest do
  @moduledoc """
  End-to-end tests for `Application.compile_env(:bond, ...)`-driven contract emission and
  the runtime toggle behavior.

  `async: false` is required because the tests manipulate process-global application config.
  """

  use ExUnit.Case, async: false

  setup do
    on_exit(fn ->
      Application.delete_env(:bond, :preconditions)
      Application.delete_env(:bond, :postconditions)
      Application.delete_env(:bond, :checks)
      Application.delete_env(:bond, :invariants)
      Application.delete_env(:bond, :overrides)
    end)
  end

  describe "compile-time `false` (override emitted, runtime defaults to off)" do
    test "preconditions: false — no PreconditionError is raised by default" do
      Application.put_env(:bond, :preconditions, false)

      defmodule PreFalse do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert PreFalse.positive(-1) == -1
    end

    test "preconditions: false but runtime put_env true — error IS raised" do
      Application.put_env(:bond, :preconditions, false)

      defmodule PreFalseFlippable do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      # Flip runtime config to true; override re-engages.
      Application.put_env(:bond, :preconditions, true)
      assert_raise Bond.PreconditionError, fn -> PreFalseFlippable.positive(-1) end
    end

    test "postconditions: false — no PostconditionError is raised by default" do
      Application.put_env(:bond, :postconditions, false)

      defmodule PostFalse do
        use Bond

        @post never_zero: result != 0
        def maybe_zero(x), do: x
      end

      assert PostFalse.maybe_zero(0) == 0
    end

    test "invariants: false at runtime — no InvariantError is raised" do
      # The SubjectInvariantSmoke fixture was compiled with the default
      # `invariants: true`; flip it off at runtime via put_env. With invariants
      # disabled, an invariant-violating struct passes through (push/2 returns
      # `{:error, :full}` because items already exceed capacity, but no
      # InvariantError raises).
      Application.put_env(:bond, :invariants, false)
      invalid = %BondTest.SubjectInvariantSmoke{items: [:a, :b, :c], capacity: 1}
      assert {:error, :full} = BondTest.SubjectInvariantSmoke.push(invalid, :d)
    end

    test "invariants flipped false then true at runtime — InvariantError returns" do
      Application.put_env(:bond, :invariants, false)
      invalid = %BondTest.SubjectInvariantSmoke{items: [:a, :b, :c], capacity: 1}
      assert {:error, :full} = BondTest.SubjectInvariantSmoke.push(invalid, :d)

      Application.put_env(:bond, :invariants, true)

      assert_raise Bond.InvariantError, fn ->
        BondTest.SubjectInvariantSmoke.push(invalid, :d)
      end
    end
  end

  describe "compile-time `:purge` (no override emitted)" do
    test "preconditions: :purge — function runs as written, no error possible" do
      # Purging the bottom of the chain requires purging every higher kind too
      # (chain validation in `Bond.Compiler.resolve_config/3`).
      Application.put_env(:bond, :preconditions, :purge)
      Application.put_env(:bond, :postconditions, :purge)
      Application.put_env(:bond, :invariants, :purge)

      defmodule PrePurge do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert PrePurge.positive(-1) == -1

      # Runtime put_env cannot bring the contract back — code wasn't compiled.
      Application.put_env(:bond, :preconditions, true)
      assert PrePurge.positive(-1) == -1
    end

    test "all chain kinds :purge — no override at all" do
      Application.put_env(:bond, :preconditions, :purge)
      Application.put_env(:bond, :postconditions, :purge)
      Application.put_env(:bond, :invariants, :purge)

      defmodule BothPurged do
        use Bond

        @pre positive_x: x > 0
        @post non_zero: result != 0
        def identity(x), do: x
      end

      assert BothPurged.identity(-1) == -1
      assert BothPurged.identity(0) == 0
    end
  end

  describe "runtime toggling (default config — preconditions: true)" do
    test "preconditions are evaluated by default" do
      defmodule DefaultPre do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert DefaultPre.positive(5) == 5
      assert_raise Bond.PreconditionError, fn -> DefaultPre.positive(-1) end
    end

    test "Application.put_env(:bond, :preconditions, false) disables eval at runtime" do
      defmodule RuntimeToggle do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      # Before put_env: evaluates.
      assert_raise Bond.PreconditionError, fn -> RuntimeToggle.positive(-1) end

      # After put_env false: skips.
      Application.put_env(:bond, :preconditions, false)
      assert RuntimeToggle.positive(-1) == -1

      # Toggle back: evaluates again.
      Application.put_env(:bond, :preconditions, true)
      assert_raise Bond.PreconditionError, fn -> RuntimeToggle.positive(-1) end
    end
  end

  describe "use Bond opts override global" do
    test "use Bond, preconditions: :purge — no precondition errors regardless of global" do
      # Global enabled, but per-module purged.
      # Purging preconditions requires also purging postconditions and invariants
      # (chain validation; see `Bond.Compiler.resolve_config/3`).
      Application.put_env(:bond, :preconditions, true)

      defmodule UseBondPurge do
        use Bond, preconditions: :purge, postconditions: :purge, invariants: :purge

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert UseBondPurge.positive(-1) == -1
    end

    test "use Bond, preconditions: true overrides global :purge" do
      # Set the whole chain to :purge globally; per-module use_opts opts back in.
      Application.put_env(:bond, :preconditions, :purge)
      Application.put_env(:bond, :postconditions, :purge)
      Application.put_env(:bond, :invariants, :purge)

      defmodule UseBondOverrideGlobal do
        use Bond, preconditions: true, postconditions: true, invariants: true

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert_raise Bond.PreconditionError, fn -> UseBondOverrideGlobal.positive(-1) end
    end
  end

  describe ":overrides match by module name" do
    test "exact module match in :overrides applies" do
      Application.put_env(:bond, :overrides, [
        {BondTest.ConditionalCompilationTest.OverridesExact,
         [preconditions: :purge, postconditions: :purge, invariants: :purge]}
      ])

      defmodule OverridesExact do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert OverridesExact.positive(-1) == -1
    end

    test "regex pattern in :overrides applies" do
      Application.put_env(:bond, :overrides, [
        {~r/OverridesRegex/, [preconditions: :purge, postconditions: :purge, invariants: :purge]}
      ])

      defmodule OverridesRegex do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert OverridesRegex.positive(-1) == -1
    end

    test "non-matching modules use global config" do
      Application.put_env(:bond, :overrides, [
        {SomeOther.Module, preconditions: :purge}
      ])

      defmodule OverridesNonMatching do
        use Bond

        @pre positive_x: x > 0
        def positive(x), do: x
      end

      assert_raise Bond.PreconditionError, fn -> OverridesNonMatching.positive(-1) end
    end

    setup do
      on_exit(fn -> Application.delete_env(:bond, :overrides) end)
      :ok
    end
  end

  describe "checks (compile-time only)" do
    test "checks: :purge — check macro expands to :ok, expression is not evaluated" do
      Application.put_env(:bond, :checks, :purge)

      parent = self()
      ref = make_ref()

      defmodule ChecksPurged do
        use Bond

        def f(_parent, _ref) do
          check send(_parent, {:check_ran, _ref}) == {:check_ran, _ref}
          :ok
        end
      end

      assert ChecksPurged.f(parent, ref) == :ok
      refute_received {:check_ran, ^ref}
    end

    test "checks: false — check macro emits a runtime guard, expression IS still evaluated when guard reads true" do
      Application.put_env(:bond, :checks, false)

      parent = self()
      ref = make_ref()

      defmodule ChecksFalse do
        use Bond

        def f(parent, ref) do
          check send(parent, {:check_ran, ref}) == {:check_ran, ref}
          :ok
        end
      end

      # With runtime default false: expression skipped.
      assert ChecksFalse.f(parent, ref) == :ok
      refute_received {:check_ran, ^ref}

      # Flip runtime to true: expression evaluated.
      Application.put_env(:bond, :checks, true)
      assert ChecksFalse.f(parent, ref) == :ok
      assert_received {:check_ran, ^ref}
    end
  end
end
