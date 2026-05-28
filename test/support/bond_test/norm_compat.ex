## Fixtures for Bond.NormCompatTest — cross-library interaction between Bond and Norm,
## both of which override `Kernel.@/1` using the identical technique (import Kernel
## except: [@: 1] + specific clause + catch-all forwarding to `Kernel.@`).
##
## Empirical finding: combining `use Bond` and `use Norm` in the same module
## fails at compile time with `function @/1 imported from both ... call is ambiguous`,
## REGARDLESS of ordering. The conflict is loud, not silent. Step 3's tests
## demonstrate this via `Code.compile_string/1`.
##
## The fixtures below show the recommended workaround: split into separate modules,
## one per contract library. Step 3 also verifies each standalone module behaves
## as expected.

defmodule BondTest.NormCompat.NormValidator do
  @moduledoc false

  use Norm

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  @contract double(n :: positive_int()) :: positive_int()
  def double(n), do: n * 2
end

defmodule BondTest.NormCompat.BondValidator do
  @moduledoc false

  use Bond

  @pre is_integer(n) and n > 0
  def double(n), do: n * 2
end
