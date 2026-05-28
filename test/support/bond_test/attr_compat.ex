## Fixtures for Bond.AttrCompatTest — attribute forwarding through Bond's @/1 override.
##
## Each module combines `use Bond` with a standard Elixir attribute pattern and includes
## at least one @pre contract to confirm Bond's own interception still works alongside
## the forwarded attribute.

# ── @derive ─────────────────────────────────────────────────────────────────

defmodule BondTest.AttrCompat.DeriveInspect do
  @moduledoc false

  use Bond
  @derive {Inspect, only: [:n]}
  defstruct [:n, :secret]

  @pre is_integer(n) and n > 0
  def new(n), do: %__MODULE__{n: n, secret: :redacted}
end

# ── @enforce_keys ────────────────────────────────────────────────────────────

defmodule BondTest.AttrCompat.EnforceKeys do
  @moduledoc false

  use Bond
  @enforce_keys [:name]
  defstruct [:name, :age]

  @pre is_binary(name)
  def new(name), do: %__MODULE__{name: name}
end

# ── typespecs: @spec / @type / @typep / @opaque ──────────────────────────────

defmodule BondTest.AttrCompat.Typespecs do
  @moduledoc false

  use Bond

  @type count :: non_neg_integer()
  @typep internal_key :: binary()
  @opaque token :: reference()

  @spec double(integer()) :: integer()
  @pre is_integer(n)
  def double(n), do: n * 2

  # Uses internal_key() in a private spec to suppress the "unused type" compiler warning.
  # @typep is forwarded by Bond's catch-all just like @type; verified by compilation.
  @spec format_key(integer()) :: internal_key()
  defp format_key(n), do: "key_#{n}"

  def get_key(n), do: format_key(n)
end

# ── @callback and @behaviour ─────────────────────────────────────────────────
#
# BehaviourDef uses Bond and declares @callback — verifying @callback is
# forwarded correctly and the module is treated as a valid behaviour.
# BehaviourImpl uses Bond, @behaviour, and @impl — all three forwarded.

defmodule BondTest.AttrCompat.BehaviourDef do
  @moduledoc false

  use Bond
  @callback transform(term()) :: term()
end

defmodule BondTest.AttrCompat.BehaviourImpl do
  @moduledoc false

  use Bond
  @behaviour BondTest.AttrCompat.BehaviourDef

  @pre not is_nil(value)
  @impl BondTest.AttrCompat.BehaviourDef
  def transform(value), do: {__MODULE__, value}
end

# ── accumulating custom attributes ───────────────────────────────────────────

defmodule BondTest.AttrCompat.AccumulatingAttr do
  @moduledoc false

  use Bond
  Module.register_attribute(__MODULE__, :rules, accumulate: true)

  @rules :rule_a
  @rules :rule_b
  @rules :rule_c

  @pre is_list(xs)
  def count(xs), do: length(xs)

  def rules, do: @rules
end

# ── @external_resource ───────────────────────────────────────────────────────

defmodule BondTest.AttrCompat.ExternalResource do
  @moduledoc false

  use Bond
  @external_resource __ENV__.file

  @pre is_integer(n) and n >= 0
  def echo(n), do: n
end
