defmodule Bond.BindingNamesTest do
  @moduledoc """
  Regression tests for #78: Bond's own generated variable names must not appear in
  the binding snapshot a user reads.

  The `binding:` line is one of the best things about a Bond violation message, so
  a name the user never wrote reads as internals leaking out. Two could reach it:
  `bond_invariant_value` (a pure duplicate of `subject`) and `bond_arg_<idx>` (the
  canonical synthesised for a position whose clauses disagreed on a name).

  The filter lives at the single point where a failure captures its binding, so it
  covers the exception message and the `[:bond, :assertion, :failure]` telemetry
  metadata alike.
  """

  use ExUnit.Case, async: true

  alias BondTest.BindingNames.Cart
  alias BondTest.BindingNames.OldExpression
  alias BondTest.BindingNames.UserNamedArg

  # Telemetry handler as an MFA capture rather than an anonymous function, which
  # telemetry warns about as a performance penalty.
  def handle_failure(_event, _measurements, meta, test), do: send(test, {:binding, meta.binding})

  # The binding from a violation, via the raised exception. The exception types are
  # named explicitly so the type checker knows `:binding` exists on the struct.
  defp binding_of(fun) do
    fun.()
    flunk("expected a Bond violation")
  rescue
    e in [Bond.PreconditionError, Bond.PostconditionError, Bond.InvariantError] -> e.binding
  end

  # The binding as a telemetry handler sees it.
  defp telemetry_binding_of(fun) do
    handler = "binding-names-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:bond, :assertion, :failure],
      &__MODULE__.handle_failure/4,
      test
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    try do
      fun.()
    rescue
      _ -> :ok
    end

    assert_receive {:binding, binding}
    binding
  end

  describe "bond_invariant_value" do
    test "is dropped from the binding, leaving subject" do
      binding = binding_of(fn -> Cart.total_cents(%Cart{items: [%{qty: -1, cents: 100}]}) end)

      assert Keyword.keys(binding) == [:subject]
      refute Keyword.has_key?(binding, :bond_invariant_value)
    end

    test "the surviving subject still carries the value" do
      binding = binding_of(fn -> Cart.total_cents(%Cart{items: [%{qty: -1, cents: 100}]}) end)

      assert %Cart{items: [%{qty: -1}]} = binding[:subject]
    end

    test "is dropped from telemetry metadata too" do
      binding =
        telemetry_binding_of(fn -> Cart.total_cents(%Cart{items: [%{qty: -1, cents: 100}]}) end)

      refute Keyword.has_key?(binding, :bond_invariant_value)
      assert Keyword.has_key?(binding, :subject)
    end
  end

  describe "bond_arg_<idx>" do
    test "is renamed to a 1-based positional label, not dropped" do
      binding = binding_of(fn -> Cart.apply_discount(%Cart{}, 150) end)

      refute Keyword.has_key?(binding, :bond_arg_0)
      assert Keyword.has_key?(binding, :arg_1)
      # Renamed rather than dropped: it is the only representation of that argument.
      assert %Cart{} = binding[:arg_1]
    end

    test "the user's own parameter names are untouched" do
      binding = binding_of(fn -> Cart.apply_discount(%Cart{}, 150) end)

      assert binding[:pct] == 150
      assert Keyword.keys(binding) |> Enum.sort() == [:arg_1, :pct]
    end

    test "is renamed in telemetry metadata too" do
      binding = telemetry_binding_of(fn -> Cart.apply_discount(%Cart{}, 150) end)

      refute Keyword.has_key?(binding, :bond_arg_0)
      assert Keyword.has_key?(binding, :arg_1)
    end

    test "backs off rather than shadowing a variable the user named arg_1" do
      binding = binding_of(fn -> UserNamedArg.f(%{}, 50) end)

      # The user's `arg_1` keeps its value and its name...
      assert binding[:arg_1] == 50
      # ...and the generated name is left alone rather than colliding with it.
      assert Keyword.has_key?(binding, :bond_arg_0)
      assert length(Keyword.get_values(binding, :arg_1)) == 1
    end
  end

  describe "names the user did write" do
    test "an old(...) key survives the filter" do
      binding = binding_of(fn -> OldExpression.shrink(5) end)

      assert Keyword.has_key?(binding, :"old(x)")
      assert binding[:"old(x)"] == 5
      assert binding[:result] == 4
      assert binding[:x] == 5
    end
  end

  describe "message rendering" do
    test "no Bond-internal name appears in the rendered message" do
      message =
        try do
          Cart.apply_discount(%Cart{}, 150)
        rescue
          e -> Exception.message(e)
        end

      refute message =~ "bond_arg"
      refute message =~ "bond_invariant_value"
      assert message =~ "arg_1:"
    end

    test "an invariant message shows subject once, not twice" do
      message =
        try do
          Cart.total_cents(%Cart{items: [%{qty: -1, cents: 100}]})
        rescue
          e -> Exception.message(e)
        end

      refute message =~ "bond_invariant_value"
      assert message =~ "subject:"
    end
  end
end
