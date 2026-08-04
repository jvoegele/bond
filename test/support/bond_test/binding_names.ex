## Fixtures for Bond.BindingNamesTest (#78).
##
## Each module produces a violation whose binding snapshot would otherwise carry
## a Bond-generated variable name — `bond_invariant_value`, or the `bond_arg_<idx>`
## synthesised when clauses disagree on what to call a position.

defmodule BondTest.BindingNames.Cart do
  @moduledoc false
  use Bond

  defstruct items: [], discount_pct: 0

  @invariant positive_quantities: Enum.all?(subject.items, &(&1.qty > 0))

  # The two clauses name the struct position differently (`cart` vs `c`), so no
  # name is agreed and the canonical becomes `bond_arg_0`.
  @pre in_range: pct >= 0 and pct <= 100
  def apply_discount(%__MODULE__{} = cart, pct) when pct == 0, do: cart
  def apply_discount(%__MODULE__{} = c, pct), do: %{c | discount_pct: pct}

  def total_cents(%__MODULE__{} = cart) do
    Enum.reduce(cart.items, 0, fn i, acc -> acc + i.qty * i.cents end)
  end
end

defmodule BondTest.BindingNames.UserNamedArg do
  @moduledoc false
  use Bond

  # A user variable already called `arg_1`, at the position *after* one whose
  # clauses disagree. Renaming `bond_arg_0` to `arg_1` would collide with it, so
  # the rename must back off rather than produce two `arg_1` keys.
  @pre small: arg_1 < 10
  def f(%{} = m, arg_1) when arg_1 == 0, do: {m, arg_1}
  def f(%{} = other, arg_1), do: {other, arg_1}
end

defmodule BondTest.BindingNames.OldExpression do
  @moduledoc false
  use Bond

  # `old(x)` is a deliberate, user-facing binding key — it must survive the filter.
  @post grew: result > old(x)
  def shrink(x) when is_integer(x), do: x - 1
end
