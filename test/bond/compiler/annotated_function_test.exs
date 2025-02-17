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
end
