defmodule Bond.ConfigTest do
  @moduledoc false

  # async: false — exercises the process-global :persistent_term runtime-modes entry.
  use ExUnit.Case, async: false

  alias Bond.Config
  alias Bond.Runtime.Eval

  @kinds [:preconditions, :postconditions, :invariants, :checks]

  setup do
    clean_slate()
    on_exit(&clean_slate/0)
    :ok
  end

  defp clean_slate do
    for kind <- @kinds, do: Application.delete_env(:bond, kind)
    Config.reset()
  end

  describe "lazy seed from application env" do
    test "an unset kind seeds to :unset (falls back to the call-site compile_default)" do
      assert Eval.modes()[:preconditions] == :unset
      # :unset means the call-site compile_default decides.
      assert Eval.should_evaluate?(:preconditions, true)
      refute Eval.should_evaluate?(:preconditions, false)
    end

    test "a kind set in app env before first read seeds to that value" do
      Application.put_env(:bond, :preconditions, false)
      # First read seeds from app env.
      assert Eval.modes()[:preconditions] == false
      refute Eval.should_evaluate?(:preconditions, true)
    end

    test "app env changed AFTER first read is NOT picked up until reset" do
      assert Eval.should_evaluate?(:preconditions, true)
      # Term is now seeded; a later app-env change is invisible.
      Application.put_env(:bond, :preconditions, false)
      assert Eval.should_evaluate?(:preconditions, true)
      # reset re-seeds from current app env.
      Config.reset()
      refute Eval.should_evaluate?(:preconditions, true)
    end
  end

  describe "enable/disable/put" do
    test "disable overrides the compile_default, enable restores evaluation" do
      Config.disable(:preconditions)
      refute Eval.should_evaluate?(:preconditions, true)

      Config.enable(:preconditions)
      assert Eval.should_evaluate?(:preconditions, false)
    end

    test "put/2 sets the boolean mode" do
      Config.put(:invariants, false)
      refute Eval.should_evaluate?(:invariants, true)
      Config.put(:invariants, true)
      assert Eval.should_evaluate?(:invariants, false)
    end

    test "a runtime override beats a later app-env change (term is authoritative once set)" do
      Config.disable(:checks)
      Application.put_env(:bond, :checks, true)
      refute Eval.should_evaluate?(:checks, true)
    end

    test "rejects unknown kinds and non-boolean values" do
      assert_raise FunctionClauseError, fn -> Config.enable(:bogus) end
      assert_raise FunctionClauseError, fn -> Config.put(:preconditions, :maybe) end
    end
  end

  describe "enabled?/1 and all/0" do
    test "enabled?/1 reflects the global runtime override" do
      Config.disable(:preconditions)
      refute Config.enabled?(:preconditions)
      Config.enable(:preconditions)
      assert Config.enabled?(:preconditions)
    end

    test "enabled?/1 falls back to the app-env default when unset" do
      assert Config.enabled?(:postconditions)
      Application.put_env(:bond, :postconditions, false)
      Config.reset()
      refute Config.enabled?(:postconditions)
    end

    test "all/0 returns a boolean per kind" do
      Config.disable(:invariants)
      modes = Config.all()
      assert Map.keys(modes) |> Enum.sort() == Enum.sort(@kinds)
      assert modes[:invariants] == false
      assert modes[:preconditions] == true
    end
  end

  describe "reset/0" do
    test "drops runtime overrides, re-seeding from app env on next read" do
      Config.disable(:preconditions)
      refute Eval.should_evaluate?(:preconditions, true)

      Config.reset()
      assert Eval.should_evaluate?(:preconditions, true)
    end
  end

  test "kinds/0 lists the four toggleable kinds" do
    assert Enum.sort(Config.kinds()) == Enum.sort(@kinds)
  end
end
