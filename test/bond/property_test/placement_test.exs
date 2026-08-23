defmodule Bond.PropertyTest.PlacementTest do
  @moduledoc """
  #81 — the two ways of misusing the property-generating macros, each of which used to
  produce an error that never mentioned Bond.

  `contract_holds/2`, `probe_contract/2`, `invariants_hold/2` and
  `server_invariants_hold/2` *define* a property: they expand to `property/2`, which
  expands to `def`. Called inside a `test` block that surfaced as
  `cannot invoke def/2 inside function/macro`, raised by `Kernel`, naming a construct the
  user never wrote. Used twice for one target it surfaced as ExUnit's
  `DuplicateTestError`, which names neither Bond nor the `:name` option that fixes it.

  The two cases that are *supposed* to compile define real ExUnit properties, because
  `use ExUnit.Case` is required before `property/2` will expand at all. Those four
  properties run as part of this suite — cheap, over `String.length/1`, and stable across
  seeds. If you are wondering where four extra properties came from, it is here.
  """

  use ExUnit.Case, async: true

  defp compile(source) do
    Code.compile_string(source)
    :compiled
  rescue
    error -> error
  end

  describe "called inside a test block" do
    test "contract_holds/2 raises a Bond error naming the placement and the fix" do
      error =
        compile("""
        defmodule Bond.PropertyTest.PlacementScratch.Nested do
          use ExUnit.Case
          use Bond.PropertyTest

          test "contracts hold" do
            contract_holds &String.length/1, args: [StreamData.string(:alphanumeric)]
          end
        end
        """)

      assert %CompileError{description: description} = error
      assert description =~ "contract_holds/2 defines a property"
      assert description =~ "must be called at the module level, not inside a test block"
      # Landing here usually means an assertion was wanted, not a property.
      assert description =~ "Bond.Test"
    end

    test "every generating macro is guarded, not just contract_holds/2" do
      for {suffix, macro, call} <- [
            {"Probe", "probe_contract/2",
             "probe_contract &String.length/1, args: [StreamData.integer()]"},
            {"Invariants", "invariants_hold/2", "invariants_hold String, constructors: []"},
            {"Server", "server_invariants_hold/2", "server_invariants_hold String, messages: []"}
          ] do
        error =
          compile("""
          defmodule Bond.PropertyTest.PlacementScratch.Nested#{suffix} do
            use ExUnit.Case
            use Bond.PropertyTest

            test "t" do
              #{call}
            end
          end
          """)

        assert %CompileError{description: description} = error
        assert description =~ "#{macro} defines a property"
      end
    end
  end

  describe "two properties for one target" do
    test "collide with a Bond error that names `:name`" do
      error =
        compile("""
        defmodule Bond.PropertyTest.PlacementScratch.Duplicate do
          use ExUnit.Case
          use Bond.PropertyTest

          contract_holds &String.length/1, args: [StreamData.string(:alphanumeric)]
          contract_holds &String.length/1, args: [StreamData.string(:ascii)]
        end
        """)

      assert %CompileError{description: description} = error
      assert description =~ "would define a second property named"
      assert description =~ "`:name`"
      refute description =~ "DuplicateTestError"
    end

    test "a distinct `:name` on either one resolves it" do
      assert compile("""
             defmodule Bond.PropertyTest.PlacementScratch.Named do
               use ExUnit.Case
               use Bond.PropertyTest

               contract_holds &String.length/1,
                 args: [StreamData.string(:alphanumeric)],
                 name: "length over alphanumeric strings"

               contract_holds &String.length/1,
                 args: [StreamData.string(:ascii)],
                 name: "length over ascii strings"
             end
             """) == :compiled
    end

    test "different targets do not collide" do
      assert compile("""
             defmodule Bond.PropertyTest.PlacementScratch.Distinct do
               use ExUnit.Case
               use Bond.PropertyTest

               contract_holds &String.length/1, args: [StreamData.string(:alphanumeric)]
               contract_holds &String.upcase/1, args: [StreamData.string(:alphanumeric)]
             end
             """) == :compiled
    end
  end
end
