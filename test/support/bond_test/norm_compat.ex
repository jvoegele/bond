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

## Coexistence in a SINGLE module: `at_annotations: false` resolves the `@`-syntax clash, and Bond's
## tolerance of externally-generated override clauses (Norm's `@contract` `@before_compile`
## injects a `defoverridable` + wrapper clause per contracted function) lets Norm's `@contract`
## and Bond's contracts live in the same module — even on the SAME function. Bond ignores
## Norm's generated wrapper clause and still wraps the function via its own `defoverridable`,
## composing with Norm's wrapper through `super`.
##
## Norm's `@contract` ALSO emits a non-overridable `def __contract__/1` helper clause per
## contract. Two or more `@contract`s in one module therefore produce non-adjacent
## `__contract__/1` clauses, which used to trip Bond's clause grouping and capped a Bond module
## at one `@contract`. Since #105 Bond skips generated `__*__` functions entirely, so those
## helper clauses are never tracked; `norm_compat_test.exs` covers the multi-contract case.
defmodule BondTest.NormCompat.Combined do
  @moduledoc false

  use Norm
  use Bond, at_annotations: false

  def positive_int, do: spec(is_integer() and (&(&1 > 0)))

  # Guarded by BOTH Norm's `@contract` (must be a positive integer) and Bond's precondition
  # (must be even). The two wrappers compose:
  #   * guarded(3)  — positive (passes Norm) but odd (fails Bond)     → PreconditionError
  #   * guarded(-2) — even (passes Bond) but negative (fails Norm)    → MismatchError
  @contract guarded(n :: positive_int()) :: positive_int()
  Bond.pre(even: rem(n, 2) == 0)
  def guarded(n), do: n * 2

  # Guarded by Bond's qualified-call contracts only, in the same Norm-using module.
  Bond.pre(is_integer(n) and n > 0)
  Bond.post(result == n * 2)
  def double(n), do: n * 2
end
