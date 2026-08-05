defmodule BondTest.StructNaming do
  @moduledoc """
  Fixture for #93: the same invariant-bearing struct referenced from function heads
  under every spelling that resolves to this module — `__MODULE__` and the fully
  qualified name — in pattern, guard, and destructure position.

  Note what is *not* here: a bare `%StructNaming{}`. Elixir does not auto-alias a
  module's own last segment, so inside `BondTest.StructNaming` that names
  `Elixir.StructNaming` — a different module — and must not be treated as this one.
  `BondTest.StructNaming.Single` covers the case where the bare name *is* the module.

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
