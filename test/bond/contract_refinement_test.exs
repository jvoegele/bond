defmodule Bond.ContractRefinementTest do
  use ExUnit.Case, async: true

  # Eiffel-style refinement of inherited behaviour contracts (#16):
  #   @pre_weaken      => effective pre  = inherited OR  weaken      (require else)
  #   @post_strengthen => effective post = inherited AND strengthen  (ensure then)
  # Refinement expressions reference the IMPLEMENTATION's own parameter names.

  # --- Behaviours (the contract-declaring side) ---

  defmodule Ledger do
    use Bond.Behaviour

    @pre positive_amount: amount > 0
    @post non_negative: result >= 0
    @callback withdraw(balance :: integer, amount :: integer) :: integer
  end

  defmodule Counter do
    use Bond.Behaviour

    @pre non_negative: count >= 0
    @callback bump(count :: integer) :: integer
  end

  # A behaviour that declares only a precondition — so @post_strengthen has no inherited post to
  # fold against (adding a postcondition by refinement is sanctioned).
  defmodule Named do
    use Bond.Behaviour

    @pre present: name != nil
    @callback render(name :: term) :: String.t()
  end

  # A behaviour that declares only a postcondition — so @pre_weaken has no inherited precondition
  # to weaken (introducing one would strengthen, which is forbidden).
  defmodule Sized do
    use Bond.Behaviour

    @post non_negative: result >= 0
    @callback size(data :: term) :: integer
  end

  # --- Implementations (the refining side) ---

  defmodule ZeroOkAccount do
    use Bond, behaviours: [Ledger]

    # Parameters named differently from the callback (bal/amt vs balance/amount) to exercise the
    # impl-name binding in the refinement.
    @impl true
    @pre_weaken zero_ok: amt == 0
    def withdraw(bal, amt), do: bal - amt
  end

  defmodule EvenAccount do
    use Bond, behaviours: [Ledger]

    @impl true
    @post_strengthen even_result: rem(result, 2) == 0
    def withdraw(balance, amount), do: balance - amount
  end

  defmodule FlexAccount do
    use Bond, behaviours: [Ledger]

    @impl true
    @pre_weaken zero_ok: amt == 0
    @post_strengthen even_result: rem(result, 2) == 0
    def withdraw(bal, amt), do: bal - amt
  end

  defmodule MultiBump do
    use Bond, behaviours: [Counter]

    @impl true
    @pre_weaken allow_neg_one: n == -1
    def bump(0), do: 0
    def bump(n), do: n + 1
  end

  defmodule Renderer do
    use Bond, behaviours: [Named]

    # No inherited postcondition; @post_strengthen adds one (legitimate refinement).
    @impl true
    @post_strengthen nonempty: String.length(result) > 0
    def render(name), do: to_string(name)
  end

  describe "precondition weakening (@pre_weaken)" do
    test "passes when the inherited precondition holds" do
      assert ZeroOkAccount.withdraw(100, 30) == 70
    end

    test "passes when the inherited precondition fails but the weakening alternative holds" do
      # amount > 0 is false for 0, but the impl weakened it to also accept amt == 0.
      assert ZeroOkAccount.withdraw(100, 0) == 100
    end

    test "fails when neither the inherited nor the weakening precondition holds" do
      error = assert_raise Bond.PreconditionError, fn -> ZeroOkAccount.withdraw(100, -5) end

      # The weakened precondition attributes to the behaviour whose contract was weakened.
      assert error.source_behaviour == Ledger
      assert error.label == :refined_precondition

      message = Exception.message(error)
      assert message =~ "precondition (inherited from Bond.ContractRefinementTest.Ledger)"
      assert message =~ "ZeroOkAccount.withdraw/2"
      # The rendered assertion shows both folded halves.
      assert message =~ "(amount > 0) or (amt == 0)"
    end

    test "the combined failure carries the weakening group's binding" do
      error = assert_raise Bond.PreconditionError, fn -> ZeroOkAccount.withdraw(100, -5) end
      assert error.binding[:amt] == -5
    end
  end

  describe "postcondition strengthening (@post_strengthen)" do
    test "passes when both the inherited and strengthening postconditions hold" do
      assert EvenAccount.withdraw(100, 30) == 70
    end

    test "fails (as the impl's own postcondition) when the strengthening clause fails" do
      # 69 is non-negative (inherited holds) but not even (strengthening fails).
      error = assert_raise Bond.PostconditionError, fn -> EvenAccount.withdraw(100, 31) end

      # The strengthening assertion is impl-authored, so it is NOT attributed to the behaviour.
      assert error.source_behaviour == nil
      assert error.label == :even_result
      refute Exception.message(error) =~ "inherited from"
    end

    test "still enforces the inherited postcondition" do
      # -40 violates the inherited non_negative post; the inherited group runs first.
      error = assert_raise Bond.PostconditionError, fn -> EvenAccount.withdraw(10, 50) end

      assert error.source_behaviour == Ledger
      assert error.label == :non_negative
    end

    test "may add a postcondition where the behaviour declared none" do
      assert Renderer.render(:hi) == "hi"
      assert_raise Bond.PostconditionError, fn -> Renderer.render("") end
    end
  end

  describe "weakening and strengthening together" do
    test "both refinements apply on the same function" do
      assert FlexAccount.withdraw(100, 30) == 70
      # weakened precondition lets amt == 0 through, and 100 is even.
      assert FlexAccount.withdraw(100, 0) == 100
      # strengthening still rejects an odd result.
      assert_raise Bond.PostconditionError, fn -> FlexAccount.withdraw(100, 31) end
      # weakened precondition still rejects a genuinely invalid call.
      assert_raise Bond.PreconditionError, fn -> FlexAccount.withdraw(100, -5) end
    end
  end

  describe "multi-clause implementations" do
    test "a refinement referencing an agreed position works across clauses" do
      assert MultiBump.bump(5) == 6
      # count >= 0 fails for -1, but the impl weakened it to also accept n == -1.
      assert MultiBump.bump(-1) == 0
    end

    test "fails when neither the inherited nor the weakening precondition holds" do
      assert_raise Bond.PreconditionError, fn -> MultiBump.bump(-2) end
    end
  end

  describe "compile-time errors" do
    test "plain @pre on an inherited operation still errors, now pointing at refinement" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule Bond.ContractRefinementTest.PlainPreViolator do
            use Bond, behaviours: [Bond.ContractRefinementTest.Ledger]

            @impl true
            @pre amount > 100
            def withdraw(balance, amount), do: balance - amount
          end
          """)
        end

      assert error.description =~ "may not declare its own"
      assert error.description =~ "@pre_weaken"
      assert error.description =~ "check/1"
    end

    test "mixing a plain @pre with @pre_weaken on an inherited op errors" do
      assert_raise CompileError, ~r/may not declare its own/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.MixedViolator do
          use Bond, behaviours: [Bond.ContractRefinementTest.Ledger]

          @impl true
          @pre amount < 1000
          @pre_weaken amount == 0
          def withdraw(balance, amount), do: balance - amount
        end
        """)
      end
    end

    test "@pre_weaken on a non-inherited function errors" do
      assert_raise CompileError, ~r/inherits no contract to refine/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.NothingToRefine do
          use Bond

          @pre_weaken x == 0
          def f(x), do: x
        end
        """)
      end
    end

    test "@pre_weaken with no inherited precondition to weaken errors" do
      assert_raise CompileError, ~r/no precondition to weaken/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.NothingToWeaken do
          use Bond, behaviours: [Bond.ContractRefinementTest.Sized]

          @impl true
          @pre_weaken data == nil
          def size(data), do: length(data)
        end
        """)
      end
    end

    test "old/1 in @post_strengthen errors" do
      assert_raise CompileError, ~r/uses `old\/1`/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.OldInStrengthen do
          use Bond, behaviours: [Bond.ContractRefinementTest.Ledger]

          @impl true
          @post_strengthen result < old(balance)
          def withdraw(balance, amount), do: balance - amount
        end
        """)
      end
    end

    test "a refinement parameter name that collides with another callback argument errors" do
      assert_raise CompileError, ~r/collides|shadow|also an argument name/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.CollisionViolator do
          use Bond, behaviours: [Bond.ContractRefinementTest.Ledger]

          # callback args are (balance, amount); the impl swaps the names, then a refinement
          # references `balance` — which is also the callback's name at position 0.
          @impl true
          @pre_weaken balance == 0
          def withdraw(amount, balance), do: amount - balance
        end
        """)
      end
    end

    test "multi-clause disagreement at a refinement-referenced position errors" do
      assert_raise CompileError, ~r/consistent top-level parameter names/, fn ->
        Code.compile_string("""
        defmodule Bond.ContractRefinementTest.DisagreeViolator do
          use Bond, behaviours: [Bond.ContractRefinementTest.Counter]

          @impl true
          @pre_weaken n == -1
          def bump(0), do: 0
          def bump(n), do: n + 1
          def bump(m) when m > 100, do: m
        end
        """)
      end
    end
  end

  describe "bare (unlabelled) refinement form" do
    test "a bare @pre_weaken works" do
      defmodule BareAccount do
        use Bond, behaviours: [Ledger]

        @impl true
        @pre_weaken amt == 0
        def withdraw(bal, amt), do: bal - amt
      end

      assert BareAccount.withdraw(100, 0) == 100
      assert_raise Bond.PreconditionError, fn -> BareAccount.withdraw(100, -1) end
    end
  end
end
