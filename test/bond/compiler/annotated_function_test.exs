defmodule Bond.Compiler.AnnotatedFunctionTest do
  @moduledoc false

  use ExUnit.Case

  alias Bond.Compiler.AnnotatedFunction
  alias Bond.Compiler.Assertion
  alias Bond.Compiler.FunctionDefinition

  @params [{:stack, [line: 80], nil}, {:elem, [line: 80], nil}]
  @guards [{:is_integer, [line: 32], [{:capacity, [line: 32], nil}]}]
  @body [do: {:new, [line: 46], [{:round, [line: 46], [{:capacity, [line: 46], nil}]}]}]

  setup [:setup_function_definitions]

  describe "new/1" do
    test "creates AnnotatedFunction from FunctionDefinition", %{function_definition: function_def} do
      assert %AnnotatedFunction{} = annotated_function = AnnotatedFunction.new(function_def)

      assert annotated_function.kind == function_def.kind
      assert annotated_function.module == function_def.module
      assert annotated_function.fun == function_def.fun
      assert annotated_function.arity == function_def.arity
      assert annotated_function.preconditions == []
      assert annotated_function.postconditions == []
      assert annotated_function.doc_attributes == []

      assert [%AnnotatedFunction.Clause{} = clause] = annotated_function.clauses
      assert clause.env == function_def.env
      assert clause.params == function_def.params
      assert clause.guards == function_def.guards
      assert clause.body == function_def.body
    end
  end

  describe "Clause.new/1" do
    test "creates a new instance of the Clause struct from the given FunctionDefinition", %{
      function_definition: function_def
    } do
      assert %AnnotatedFunction.Clause{} = clause = AnnotatedFunction.Clause.new(function_def)

      assert clause.env == function_def.env
      assert clause.params == function_def.params
      assert clause.guards == function_def.guards
      assert clause.body == function_def.body
    end
  end

  describe "add_clause/2" do
    test "adds clause when given a FunctionDefinition with matching mfa", %{
      two_clause_function_clause1: clause_def1,
      two_clause_function_clause2: clause_def2
    } do
      annotated_function = AnnotatedFunction.new(clause_def1)
      assert [clause1] = annotated_function.clauses
      assert Macro.to_string(clause1.params) == "[input]"

      annotated_function = AnnotatedFunction.add_clause(annotated_function, clause_def2)
      assert [^clause1, clause2] = annotated_function.clauses
      assert Macro.to_string(clause2.params) == "[input]"
    end

    test "error when given a FunctionDefinition with different mfa", %{
      function_definition: function_def,
      one_clause_function: one_clause_function
    } do
      annotated_function = AnnotatedFunction.new(one_clause_function)

      assert_raise FunctionClauseError, fn ->
        AnnotatedFunction.add_clause(annotated_function, function_def)
      end
    end
  end

  describe "put_preconditions/2" do
    setup [:setup_assertions]

    test "adds preconditions to the annotated function", %{
      function_definition: function_def,
      preconditions: preconditions
    } do
      annotated_function =
        function_def
        |> AnnotatedFunction.new()
        |> AnnotatedFunction.put_preconditions(preconditions)

      assert AnnotatedFunction.has_preconditions?(annotated_function)
      assert annotated_function.preconditions == preconditions
      refute AnnotatedFunction.has_postconditions?(annotated_function)
      assert annotated_function.postconditions == []
      assert AnnotatedFunction.override?(annotated_function)
    end
  end

  describe "put_postconditions/2" do
    setup [:setup_assertions]

    test "adds postconditions to the annotated function", %{
      function_definition: function_def,
      postconditions: postconditions
    } do
      annotated_function =
        function_def
        |> AnnotatedFunction.new()
        |> AnnotatedFunction.put_postconditions(postconditions)

      assert AnnotatedFunction.has_postconditions?(annotated_function)
      assert annotated_function.postconditions == postconditions
      refute AnnotatedFunction.has_preconditions?(annotated_function)
      assert annotated_function.preconditions == []
      assert AnnotatedFunction.override?(annotated_function)
    end
  end

  describe "put_doc_attributes/2" do
    @doc_string "The D.O.C. and the Doctor"
    @doc_attribute {[line: 42], @doc_string}
    @doc_attribute_keyword {[line: 43],
                            [artist: "The D.O.C.", title: "Portrait of a Master Piece"]}

    test "adds doc attributes to the annotated function", %{
      two_clause_function_clause1: clause_def1,
      two_clause_function_clause2: clause_def2
    } do
      annotated_function =
        clause_def1
        |> AnnotatedFunction.new()
        |> AnnotatedFunction.put_doc_attributes([@doc_attribute])

      assert AnnotatedFunction.has_doc_attributes?(annotated_function)
      assert annotated_function.doc_attributes == [@doc_attribute]

      annotated_function =
        annotated_function
        |> AnnotatedFunction.add_clause(clause_def2)
        |> AnnotatedFunction.put_doc_attributes([@doc_attribute_keyword])

      assert annotated_function.doc_attributes == [@doc_attribute, @doc_attribute_keyword]
    end
  end

  describe "apply_contract/1" do
    setup [:setup_assertions, :setup_annotated_functions]

    test "makes original function overridable", %{
      one_clause_annotated_function: annotated_function
    } do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      assert {:defoverridable, _, [[add: 2]]} = first_block_clause(ast)
    end

    test "emits a single @doc Module.put_attribute call for one-clause function",
         %{one_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      doc_clauses = doc_put_attribute_clauses(ast)

      assert [{_line, doc}] = doc_clauses
      assert doc =~ ~r"#{@doc_string}"
      assert doc =~ ~r"#### Preconditions"
      assert doc =~ ~r"requires1: x > 0"
      assert doc =~ ~r"#### Postconditions"
      assert doc =~ ~r"ensures1: result < x"
    end

    test "emits a @doc Module.put_attribute call per doc attribute for a multi-clause function",
         %{two_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      doc_clauses = doc_put_attribute_clauses(ast)

      # The two-clause fixture has one string @doc and one keyword @doc.
      assert [{_line1, string_doc}, {_line2, keyword_doc}] = doc_clauses
      assert string_doc =~ ~r"#{@doc_string}"
      assert string_doc =~ ~r"#### Preconditions"
      assert keyword_doc == [artist: "The D.O.C.", title: "Portrait of a Master Piece"]
    end

    test "emits one wrapper clause per user clause, each binding the canonical name",
         %{two_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      wrappers = override_def_clauses(ast)

      # 0.17.0 emits one override clause per user clause to preserve Elixir's
      # multi-clause dispatch. Both bind the canonical name `input`. Each user
      # clause's `when` guard is reproduced on the wrapper head (rc.4, GitHub
      # #22) so dispatch survives — here the two clauses guard on `is_list` and
      # `is_map`.
      assert length(wrappers) == 2

      Enum.each(wrappers, fn wrapper ->
        assert {:def, _, [{:when, _, [{:new, _, [{:input, _, _}]}, guard]}, [do: do_block]]} =
                 wrapper

        guard_code = Macro.to_string(guard)
        assert guard_code =~ ~r/is_list\(input\)|is_map\(input\)/

        code = Macro.to_string(do_block)
        assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:preconditions,\s*true"

        # Lifted-defp arguments flow in unwrapped; the lifted defps carry
        # `@dialyzer {:nowarn_function, ...}` to suppress narrowed-type warnings instead of
        # laundering each argument through `Bond.Predicates.__opaque__/1`.
        assert code =~
                 ~r/Bond\.Runtime\.Eval\.evaluate_preconditions\(fn ->\s+__bond_preconditions__new__1\(input\)\s+end\)/s

        assert code =~ ~r"var!\(result\) = super\(input\)"
        assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:postconditions,\s*true"

        assert code =~
                 ~r/Bond\.Runtime\.Eval\.evaluate_postconditions\(fn ->\s+__bond_postconditions__new__1\(\s*input,\s*var!\(result\)\s*\)\s+end\)/s

        assert code =~ ~r"var!\(result\)$"
      end)
    end

    test "emits lifted defps for the precondition and postcondition assertion bodies",
         %{two_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      defps = lifted_defp_clauses(ast)

      # For multi-clause functions the lifted defps use the canonical top-level
      # name (`input` here), not any individual clause's full pattern.
      assert {:__bond_preconditions__new__1, [{:input, _, _}], pre_body} =
               Enum.find(defps, fn {name, _, _} -> name == :__bond_preconditions__new__1 end)

      pre_code = Macro.to_string(pre_body)
      assert pre_code =~ ~r"import Bond\.Predicates"
      # The if/throw plumbing now lives in `Bond.Runtime.Eval.check_assertion/3`, so the
      # lifted defp body is a routing call rather than an inline branch — this is what
      # eliminates the `pattern_match` "Pattern: false, Type: true" warning Dialyzer
      # would otherwise emit when the user's assertion is statically true.
      assert pre_code =~ ~r"Bond\.Runtime\.Eval\.check_assertion\(\s*x > 0,"
      refute pre_code =~ ~r"\bthrow\("

      assert {:__bond_postconditions__new__1, post_params, post_body} =
               Enum.find(defps, fn {name, _, _} -> name == :__bond_postconditions__new__1 end)

      # `input` (the canonical name) plus a `var!(result)` parameter at the end.
      assert length(post_params) == 2

      post_code = Macro.to_string(post_body)
      assert post_code =~ ~r"import Bond\.Predicates"
      assert post_code =~ ~r"Bond\.Runtime\.Eval\.check_assertion\(\s*result < x,"
    end

    test "emits a @dialyzer nowarn_function attribute for each lifted defp",
         %{two_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)

      # Instead of laundering argument types through `Bond.Predicates.__opaque__/1` at the
      # call boundary, each lifted defp carries a nowarn attribute so a `@pre`/`@post`
      # duplicating a typespec-implied guard doesn't surface a pattern_match warning.
      nowarns = nowarn_function_entries(ast)

      defp_arities =
        lifted_defp_clauses(ast) |> Enum.map(fn {name, params, _} -> {name, length(params)} end)

      # Exactly one nowarn per lifted defp, matching name and arity.
      assert Enum.sort(nowarns) == Enum.sort(defp_arities)
      assert {:__bond_preconditions__new__1, 1} in nowarns
      assert {:__bond_postconditions__new__1, 2} in nowarns
    end
  end

  describe "apply_contract/2 conditional compilation" do
    setup [:setup_assertions, :setup_annotated_functions]

    test "preconditions purged — override has no precondition eval, doc has no #### Preconditions",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: :purge,
          postconditions: true
        })

      refute is_nil(ast)

      doc = doc_put_attribute_clauses(ast) |> List.first() |> elem(1)
      assert doc =~ ~r"#{@doc_string}"
      refute doc =~ ~r"#### Preconditions"
      assert doc =~ ~r"#### Postconditions"

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      refute code =~ ~r"evaluate_preconditions"
      refute code =~ ~r"__bond_preconditions__"
      assert code =~ ~r"evaluate_postconditions"
      assert code =~ ~r"var!\(result\) = super"

      defp_names = lifted_defp_clauses(ast) |> Enum.map(fn {name, _, _} -> name end)

      refute Enum.any?(
               defp_names,
               &(Atom.to_string(&1) |> String.starts_with?("__bond_preconditions__"))
             )

      assert Enum.any?(
               defp_names,
               &(Atom.to_string(&1) |> String.starts_with?("__bond_postconditions__"))
             )
    end

    test "postconditions purged — override has no postcondition eval, doc has no #### Postconditions",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: true,
          postconditions: :purge
        })

      refute is_nil(ast)

      doc = doc_put_attribute_clauses(ast) |> List.first() |> elem(1)
      assert doc =~ ~r"#### Preconditions"
      refute doc =~ ~r"#### Postconditions"

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      assert code =~ ~r"evaluate_preconditions"
      refute code =~ ~r"evaluate_postconditions"
      refute code =~ ~r"__bond_postconditions__"

      defp_names = lifted_defp_clauses(ast) |> Enum.map(fn {name, _, _} -> name end)

      assert Enum.any?(
               defp_names,
               &(Atom.to_string(&1) |> String.starts_with?("__bond_preconditions__"))
             )

      refute Enum.any?(
               defp_names,
               &(Atom.to_string(&1) |> String.starts_with?("__bond_postconditions__"))
             )
    end

    test "both purged returns nil", %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: :purge,
          postconditions: :purge
        })

      assert is_nil(ast)
    end

    test "preconditions: false — override emits evaluate_preconditions with false default, doc HAS section",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: false,
          postconditions: true
        })

      refute is_nil(ast)

      doc = doc_put_attribute_clauses(ast) |> List.first() |> elem(1)
      assert doc =~ ~r"#### Preconditions"
      assert doc =~ ~r"#### Postconditions"

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      # Override gates the evaluate call with should_evaluate?, passing the compile-time
      # default of `false`. Eval's should_evaluate? uses that default when the kind's
      # runtime mode is `:unset` (see Bond.Runtime.Eval and Bond.Config).
      assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:preconditions,\s*false"

      assert code =~
               ~r/Bond\.Runtime\.Eval\.evaluate_preconditions\(fn ->\s+__bond_preconditions__add__2\(x, y\)\s+end\)/s
    end

    test "preconditions: true — override emits evaluate_preconditions with true default",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: true,
          postconditions: true
        })

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:preconditions,\s*true"

      assert code =~
               ~r/Bond\.Runtime\.Eval\.evaluate_preconditions\(fn ->\s+__bond_preconditions__add__2\(x, y\)\s+end\)/s

      assert code =~ ~r"Bond\.Runtime\.Eval\.should_evaluate\?\(\s*:postconditions,\s*true"

      assert code =~
               ~r/Bond\.Runtime\.Eval\.evaluate_postconditions\(fn ->\s+__bond_postconditions__add__2\(\s*x,\s*y,\s*var!\(result\)\s*\)\s+end\)/s
    end

    test "function with only preconditions: purging postconditions still emits override" do
      function_def =
        FunctionDefinition.new(
          __ENV__,
          :def,
          :only_pre,
          quote(do: [x]),
          [],
          quote(do: x)
        )

      preconditions = [Assertion.new(:precondition, :positive, quote(do: x > 0), __ENV__)]

      annotated_function =
        function_def
        |> AnnotatedFunction.new()
        |> AnnotatedFunction.put_preconditions(preconditions)

      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: true,
          postconditions: :purge
        })

      refute is_nil(ast)
    end

    test "function with only preconditions: purging preconditions returns nil" do
      function_def =
        FunctionDefinition.new(
          __ENV__,
          :def,
          :only_pre,
          quote(do: [x]),
          [],
          quote(do: x)
        )

      preconditions = [Assertion.new(:precondition, :positive, quote(do: x > 0), __ENV__)]

      annotated_function =
        function_def
        |> AnnotatedFunction.new()
        |> AnnotatedFunction.put_preconditions(preconditions)

      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: :purge,
          postconditions: true
        })

      assert is_nil(ast)
    end
  end

  defp first_block_clause({:__block__, _, [first | _]}), do: first
  defp first_block_clause(ast), do: ast

  defp block_clauses({:__block__, _, clauses}), do: clauses
  defp block_clauses(ast), do: [ast]

  defp doc_put_attribute_clauses(ast) do
    ast
    |> block_clauses()
    |> Enum.flat_map(fn
      {{:., _, [{:__aliases__, _, [:Module]}, :put_attribute]}, _, [_module, :doc, {line, value}]} ->
        [{line, value}]

      _ ->
        []
    end)
  end

  defp override_def_clause(ast) do
    ast
    |> block_clauses()
    |> Enum.find(fn
      {:def, _, _} -> true
      _ -> false
    end)
  end

  defp override_def_clauses(ast) do
    ast
    |> block_clauses()
    |> Enum.filter(fn
      {:def, _, _} -> true
      _ -> false
    end)
  end

  # Extracts `{name, arity}` for each `@dialyzer {:nowarn_function, [{name, arity}]}`
  # attribute in `ast`.
  defp nowarn_function_entries(ast) do
    ast
    |> block_clauses()
    |> Enum.flat_map(fn
      {:@, _, [{:dialyzer, _, [{:nowarn_function, entries}]}]} -> entries
      _ -> []
    end)
  end

  # Extracts `{fun_name, params, body_ast}` for each `defp __bond_*__*` clause in `ast`.
  defp lifted_defp_clauses(ast) do
    ast
    |> block_clauses()
    |> Enum.flat_map(fn
      {:defp, _, [{name, _, params}, [do: body]]} when is_atom(name) and is_list(params) ->
        if String.starts_with?(Atom.to_string(name), "__bond_") do
          [{name, params, body}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp setup_function_definitions(_) do
    one_clause_function =
      FunctionDefinition.new(
        __ENV__,
        :def,
        :add,
        quote(do: [x, y]),
        quote(do: []),
        quote(do: x + y)
      )

    # Two clauses for new/1, sharing the canonical top-level name `input`
    # but dispatching on shape via guards. 0.17.0's consistent-naming rule
    # requires all clauses to use the same top-level name at each position.
    two_clause_function_clause1 =
      FunctionDefinition.new(
        __ENV__,
        :def,
        :new,
        quote(do: [input]),
        quote(do: [is_list(input)]),
        quote(do: Map.new(input))
      )

    two_clause_function_clause2 =
      FunctionDefinition.new(
        __ENV__,
        :def,
        :new,
        quote(do: [input]),
        quote(do: [is_map(input)]),
        quote(do: input)
      )

    {:ok,
     function_definition: FunctionDefinition.new(__ENV__, :def, :foo, @params, @guards, @body),
     one_clause_function: one_clause_function,
     two_clause_function_clause1: two_clause_function_clause1,
     two_clause_function_clause2: two_clause_function_clause2}
  end

  defp setup_assertions(_) do
    preconditions = [Assertion.new(:precondition, :requires1, quote(do: x > 0), __ENV__)]
    postconditions = [Assertion.new(:postcondition, :ensures1, quote(do: result < x), __ENV__)]

    {:ok, preconditions: preconditions, postconditions: postconditions}
  end

  defp setup_annotated_functions(context) do
    one_clause_annotated_function =
      context.one_clause_function
      |> AnnotatedFunction.new()
      |> AnnotatedFunction.put_preconditions(context.preconditions)
      |> AnnotatedFunction.put_postconditions(context.postconditions)
      |> AnnotatedFunction.put_doc_attributes([@doc_attribute])

    two_clause_annotated_function =
      context.two_clause_function_clause1
      |> AnnotatedFunction.new()
      |> AnnotatedFunction.put_preconditions(context.preconditions)
      |> AnnotatedFunction.put_postconditions(context.postconditions)
      |> AnnotatedFunction.put_doc_attributes([@doc_attribute])
      |> AnnotatedFunction.add_clause(context.two_clause_function_clause2)
      |> AnnotatedFunction.put_doc_attributes([@doc_attribute_keyword])

    {:ok,
     one_clause_annotated_function: one_clause_annotated_function,
     two_clause_annotated_function: two_clause_annotated_function}
  end
end
