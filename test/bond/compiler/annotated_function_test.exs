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
      assert Macro.to_string(clause1.params) == "[list]"

      annotated_function = AnnotatedFunction.add_clause(annotated_function, clause_def2)
      assert [^clause1, clause2] = annotated_function.clauses
      assert Macro.to_string(clause2.params) == "[map]"
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

    test "override clause delegates to super/1 with the first clause's params",
         %{two_clause_annotated_function: annotated_function} do
      ast = AnnotatedFunction.apply_contract(annotated_function)
      override = override_def_clause(ast)

      assert {:def, _, [{:new, _, [{:list, _, _}]}, [do: do_block]]} = override

      code = Macro.to_string(do_block)
      assert code =~ ~r"preconditions_fun ="
      assert code =~ ~r"if x > 0"
      assert code =~ ~r"Bond.Runtime.Eval.evaluate_preconditions\(preconditions_fun\)"
      assert code =~ ~r"var!\(result\) = super\(list\)"
      assert code =~ ~r"postconditions_fun ="
      assert code =~ ~r"Bond.Runtime.Eval.evaluate_postconditions\(postconditions_fun\)"
      assert code =~ ~r"var!\(result\)$"
      assert code =~ ~r"throw.*:assertion_failure"
      assert code =~ ~r"if result < x"
    end
  end

  describe "apply_contract/2 conditional compilation" do
    setup [:setup_assertions, :setup_annotated_functions]

    test "preconditions disabled — override has no precondition eval, doc has no #### Preconditions",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: false,
          postconditions: true
        })

      refute is_nil(ast)

      doc = doc_put_attribute_clauses(ast) |> List.first() |> elem(1)
      assert doc =~ ~r"#{@doc_string}"
      refute doc =~ ~r"#### Preconditions"
      assert doc =~ ~r"#### Postconditions"

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      refute code =~ ~r"preconditions_fun ="
      refute code =~ ~r"evaluate_preconditions"
      assert code =~ ~r"evaluate_postconditions"
      assert code =~ ~r"var!\(result\) = super"
    end

    test "postconditions disabled — override has no postcondition eval, doc has no #### Postconditions",
         %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: true,
          postconditions: false
        })

      refute is_nil(ast)

      doc = doc_put_attribute_clauses(ast) |> List.first() |> elem(1)
      assert doc =~ ~r"#### Preconditions"
      refute doc =~ ~r"#### Postconditions"

      override = override_def_clause(ast)
      code = Macro.to_string(elem(override, 2) |> List.last() |> Keyword.get(:do))

      assert code =~ ~r"evaluate_preconditions"
      refute code =~ ~r"postconditions_fun ="
      refute code =~ ~r"evaluate_postconditions"
    end

    test "both disabled returns nil", %{one_clause_annotated_function: annotated_function} do
      ast =
        AnnotatedFunction.apply_contract(annotated_function, %{
          preconditions: false,
          postconditions: false
        })

      assert is_nil(ast)
    end

    test "function with only preconditions: disabling postconditions still emits override" do
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
          postconditions: false
        })

      refute is_nil(ast)
    end

    test "function with only preconditions: disabling preconditions returns nil" do
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
          preconditions: false,
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

    two_clause_function_clause1 =
      FunctionDefinition.new(
        __ENV__,
        :def,
        :new,
        quote(do: [list]),
        quote(do: [is_list(list)]),
        quote(do: Map.new(list))
      )

    two_clause_function_clause2 =
      FunctionDefinition.new(
        __ENV__,
        :def,
        :new,
        quote(do: [map]),
        quote(do: [is_map(map)]),
        quote(do: map)
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
