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

## Coexistence in a SINGLE module via the `at_syntax: false` escape hatch.
##
## `use Bond, at_syntax: false` leaves `Kernel.@/1` untouched, so Norm keeps ownership of `@`
## while Bond contracts are written as fully-qualified `Bond.pre` / `Bond.post` calls. The fact
## that THIS MODULE COMPILES is the assertion that the ambiguous-import conflict is gone —
## contrast with the `Code.compile_string/1` cases below, where mixing `@pre` and `@contract`
## fails with `function @/1 imported from both ... call is ambiguous`.
##
## Norm itself is fully functional here (`spec`/`conform!`), proving `@` and the rest of Norm
## are intact.
##
## SCOPE: this module does NOT use Norm's `@contract`. The escape hatch fixes the `@`-syntax
## clash, but Norm's `@contract` ALSO rewrites function definitions (its `@before_compile`
## injects a `defoverridable` + wrapper clause per contracted function). Those generated
## clauses are observed by Bond's own `@on_definition`, so Bond's FSM sees the function defined
## twice and rejects it. That def-rewriting conflict is independent of the `@`-syntax clash and
## is NOT resolved by `at_syntax: false`; `norm_compat_test.exs` documents it explicitly.
defmodule BondTest.NormCompat.Combined do
  @moduledoc false

  use Norm
  use Bond, at_syntax: false

  # Norm is fully functional in this module: `@` is Norm's, and `spec`/`conform!` work.
  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  def conform_positive(n), do: Norm.conform!(n, positive_int())

  # Bond contracts via qualified calls coexist in the same module.
  Bond.pre(is_integer(n) and n > 0)
  Bond.post(result == n * 2)
  def double(n), do: n * 2
end
