defmodule BondTest.StructNaming do
  @moduledoc """
  Fixture for #93: the same invariant-bearing struct referenced from function heads
  under every spelling that resolves to this module — `__MODULE__` and the fully
  qualified name — in pattern, guard, and destructure position.

  Note what is *not* here: a bare `%StructNaming{}` with no alias in scope. Elixir does
  not auto-alias a module's own last segment, so inside `BondTest.StructNaming` that
  names `Elixir.StructNaming` — a different module — and must not be treated as this
  one. `Single` covers the case where the bare name *is* the module, and `SelfAliased`
  the case where an explicit `alias` makes the short name mean this module after all.

  Bodies return `:ok` rather than doing work, so a `Bond.InvariantError` from any of
  these can only have come from the entry check.
  """

  use Bond

  defstruct items: [], capacity: 0

  @invariant within: length(subject.items) <= subject.capacity

  # --- pattern position -----------------------------------------------------

  def via_module_pattern(%__MODULE__{} = _s), do: :ok
  def via_qualified_pattern(%BondTest.StructNaming{} = _s), do: :ok

  # --- guard position -------------------------------------------------------

  def via_module_guard(s) when is_struct(s, __MODULE__), do: :ok
  def via_qualified_guard(s) when is_struct(s, BondTest.StructNaming), do: :ok

  # --- destructure-only position --------------------------------------------

  def via_module_destructure(%__MODULE__{items: _items}), do: :ok
  def via_qualified_destructure(%BondTest.StructNaming{items: _items}), do: :ok

  defmodule Other do
    @moduledoc "An unrelated struct that must not be mistaken for another module's."
    defstruct count: 0
  end

  defmodule Unrelated do
    @moduledoc """
    Declares its own invariant, and has a function whose head matches a *different*
    module's struct. That head must not be treated as this module's struct — if it
    were, `subject` would be bound to an `Other` and the invariant would evaluate
    against the wrong value.
    """

    use Bond

    defstruct count: 0

    @invariant non_negative: subject.count >= 0

    @bond_warn_skipped_invariants false
    def touch(%BondTest.StructNaming.Other{} = _other), do: :ok
  end
end

defmodule BondTest.StructNaming.SelfAliased do
  @moduledoc """
  The `alias __MODULE__` idiom: the short name genuinely resolves to this module, so
  heads written with it must be detected. Bond reads the module's alias table from the
  `Macro.Env` at `__before_compile__` to resolve this exactly.
  """

  use Bond

  alias __MODULE__, as: Cart

  defstruct items: [], capacity: 0

  @invariant within: length(subject.items) <= subject.capacity

  def via_self_alias(%Cart{} = _s), do: :ok
  def via_self_alias_guard(s) when is_struct(s, Cart), do: :ok
end

defmodule BondTest.StructNaming.ForeignAlias do
  @moduledoc """
  The mirror case: an alias in scope that points at a *different* module. A head using
  it must NOT be treated as this module's struct — binding `subject` to a foreign struct
  would evaluate the invariant against a value that has none of its fields.
  """

  use Bond

  alias BondTest.StructNaming.Other, as: Cart

  defstruct items: [], capacity: 0

  @invariant within: length(subject.items) <= subject.capacity

  @bond_warn_skipped_invariants false
  def touch(%Cart{} = _foreign), do: :ok
end

defmodule Single do
  @moduledoc """
  A single-segment module, where the bare name genuinely *is* the module — so
  `%Single{}` and `%__MODULE__{}` denote the same struct and both must be detected.
  """

  use Bond

  defstruct count: 0

  @invariant non_negative: subject.count >= 0

  def via_bare_name(%Single{} = _s), do: :ok
  def via_bare_name_guard(s) when is_struct(s, Single), do: :ok
end

defmodule BondTest.NestedStructHeads do
  @moduledoc """
  Fixture for #84: the struct carried inside a tuple, map, or list pattern in the head.

  Every function here *discards* the struct rather than returning it, so the exit check
  cannot mask a missing entry check — a `Bond.InvariantError` can only have come from
  the entry check.
  """

  use Bond

  defstruct v: 1

  @invariant positive: subject.v > 0

  def from_tuple({:wrapped, %__MODULE__{} = s}), do: {:ok, s.v}
  def from_map(%{payload: %__MODULE__{} = s}), do: {:ok, s.v}
  def from_list([%__MODULE__{} = s | _rest]), do: {:ok, s.v}
  def from_nested({:outer, {:inner, %__MODULE__{} = s}}), do: {:ok, s.v}
  def reversed({:wrapped, s = %__MODULE__{}}), do: {:ok, s.v}

  # Two structs nested in one head: both are checked, left to right.
  def pair({%__MODULE__{} = a, %__MODULE__{} = b}), do: {:ok, a.v, b.v}

  # Destructure-only at depth binds nothing to check against — documented as not
  # detected, and the reason the guide tells you to add `= name`.
  @bond_warn_skipped_invariants false
  def destructure_only({:wrapped, %__MODULE__{v: v}}), do: {:ok, v}
end
