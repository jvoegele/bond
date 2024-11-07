# Bond

<!-- README START -->

Design By Contract for Elixir.

Bond provides thorough support for contract programming (also known as
"Design By Contract") for Elixir.

As described on [Wikipedia](https://en.wikipedia.org/wiki/Design_by_contract):

> Design by contract (DbC), also known as contract programming, programming by
> contract and design-by-contract programming, is an approach for designing
> software.
>
> It prescribes that software designers should define formal, precise and
> verifiable interface specifications for software components, which extend the
> ordinary definition of
> [abstract data types](https://en.wikipedia.org/wiki/Abstract_data_type) with
> preconditions, postconditions and invariants. These specifications are referred
> to as "contracts", in accordance with a conceptual metaphor with the conditions
> and obligations of business contracts.
>
> The term was coined by
> [Bertrand Meyer](https://en.wikipedia.org/wiki/Bertrand_Meyer) in connection
> with his design of the
> [Eiffel programming language](https://en.wikipedia.org/wiki/Eiffel_(programming_language))
> and first described in various articles starting in 1986 and the two successive
> editions (1988, 1997) of his book
> [_Object-Oriented Software Construction_](https://en.wikipedia.org/wiki/Object-Oriented_Software_Construction).
>
> Design by contract has its roots in work on
> [formal verification](https://en.wikipedia.org/wiki/Formal_verification),
> [formal specification](https://en.wikipedia.org/wiki/Formal_specification) and
> [Hoare logic](https://en.wikipedia.org/wiki/Hoare_logic).

Bond applies the central ideas of contract programming to Elixir and provides
support for attaching preconditions and postconditions to function definitions
and conditionally evaluating them based on compile-time configuration.

## Usage

Bond introduces two special annotations that can be used to define
contracts for functions:

- `@pre` for defining function _preconditions_
- `@post` for defining function _postconditions_

Both of these annotations allow for attaching one or more assertions (with
optional labels) to functions. These assertions are attached to functions at
compile-time and evaluated at run-time.

To use these annotations and other features of Bond, you must `use` the `Bond`
module in your own module(s). For example:

```elixir
defmodule Math do
  use Bond

  @pre numeric_x: is_number(x), non_negative_x: x >= 0
  @post float_result: is_float(result),
        non_negative_result: result >= 0.0,
        "sqrt of 0 is 0": (x == 0) ~> (result === 0.0),
        "sqrt of 1 is 1": (x == 1) ~> (result === 1.0),
        "x > 1 implies result smaller than x": (x > 1) ~> (result < x)
  def sqrt(x), do: :math.sqrt(x)
end
```

The simple example above demonstrates how to define assertions in preconditions
and postconditions. Assertions are simple boolean expressions, which have
access to the bindings of the function that they precede. Assertions may have
optional labels associated with them to aid in interpretation, either by human
readers of the source code or in debugging assertion failures.

There are several variants of the syntax for assertions
described in the section [Assertion syntax](#module-assertion-syntax) below.

Assertions are evaluated at run-time; preconditions are evaluated prior to
execution of the function body while postconditions are evaluated after
the function, given that the function exits normally. Both preconditions and
postconditions have access to the parameters of the function. Postconditions
additionally have access to the `result` variable, which is bound to the result
of the function, as well as `old` expressions (discussed in
[`old` expressions](#module-old-expressions) below).

Finally, `Bond` also provides a `check/1` macro that can be used to place
assertions at arbitrary points in the code. This facility can be used as a form
of "sanity check" to verify that assumptions (about the state of the system or
results of calculations, for example) hold true. Note, however, that these
checks should not be used for verifying input data, data from external
systems, or for any purpose for which if the check were removed it would
compromise the integrity of the system. This is particularly true if these
checks can be disabled via configuration.

> #### `use Bond` {: .info}
>
> When you `use Bond`, the `Bond` module will override several `Kernel` macros
> in order to support attaching preconditions and postconditions to functions.
> Specifically:
>
> - `Kernel.@/1` is overridden by `Bond.@/1`
> - `Kernel.def/2` is overridden by `Bond.def/2`
> - `Kernel.defp/2` is overridden by `Bond.defp/2`
>
> `use Bond` will also import the `Bond` module so that the `check/1` and
> `check/2` macros are available for use.
>
> Additionally, the `Bond.Predicates` module is automatically imported for all
> preconditions, postconditions, and checks, so that the predicate functions and
> operators that are defined therein can be used for assertions.
> `Bond.Predicates` can be explicitly imported into modules for use outside of
> assertions.

## Assertion syntax

Assertions in Bond are conditional Elixir expressions, optionally associated
with a textual label (either an atom or a string). These assertions may appear
in `@pre` or `@post` expressions, or in calls to `check/1` or `check/2`.

Bond offers considerable flexibility in its assertion syntax; assertions may
take any of the following forms:

- `expression` - a "bare" expression without any associated label
- `label, expression` - an expression preceded by a string or atom label
- `expression, label` - an expression followed by a string or atom label
- `label_1: expression_1, label_2: expression_2` - a keyword list with labels as
  the keys and expressions as the associated values

Bond also provides the `Bond.Predicates` module with predicates that are often
useful in assertions. These include an "exclusive or" predicate and a logical
implication predicate. The `Bond.Predicates` module is automatically imported
for preconditions, postconditions, and `check` assertions. See the
`Bond.Predicates` documentation for further details.

## `old` expressions

`old` expressions allow postconditions to access the value of any arbitrary
expression _prior to_ execution of the function body. Postconditions are
"pre-compiled" in such a way that any `old` expressions that appear in
assertions are resolved to the value that they had at the start of function
execution.

While this facility is not particularly relevant for purely functional code,
it can be useful for stateful components of an application.

For example, imagine a simple, stateful `Counter` module that uses an `Agent`
to store the current count (some Agent code omitted for brevity):

```elixir
defmodule Counter do
  use Bond

  def get_count(agent) do
    Agent.get(agent, & &1)
  end

  @post count_incremented_by_1: get_count(agent) == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
end
```

Notice how the `old` expression captures the value of `get_count/1` prior to
execution of the function, and this value is used to verify that the value of
`get_count/1` has been updated as expected.

Note, however, that there is a potential race condition in the above code.
Since Agents are inherently concurrent, it is possible that another call to
`increment_count/1` is interleaved between execution of the function body and
the call to `get_count/1` that appears in the postcondition. In this scenario
the postcondition would fail because the new value of `get_count/1` would be
at least 2 greater than the old value captured in the postcondition, rather
than exactly 1 greater as specified in the `count_incremented_by_1` assertion.

As a first attempt to alleviate this race condition we can update the
`increment_count/1` function so that it returns the updated count as its result
and use that result in the postcondition directly:

```elixir
  @post returns_updated_count: result == old(get_count(agent)) + 1
  def increment_count(agent) do
    Agent.get_and_update(agent, fn count ->
      new_count = count + 1
      {new_count, new_count}
    end)
  end
```

In this version we utilize `Agent.get_and_update/3` to update the counter and
return the updated counter value in one operation. The new counter value is the
`result` of the function which can be used in postconditions. The
`returns_updated_count` assertion compares this `result` to the `old` value of
`get_count/1` to ensure that it was incremented by exactly 1.

However, as you may have noticed, it is still possible for another call to
`increment_count/1` to be interleaved between the call to `get_count/1` in the
`old` expression of the postcondition and the call to `Agent.get_and_update/3`
in the function body. Alas, there is no way to "lock" an Agent over multiple
operations to ensure that there are no concurrent updates to the Agent state.
Therefore, our only choice is to soften the guarantee made by our
postcondition:

```elixir
  @post count_increased: get_count(agent) > old(get_count(agent))
  def increment_count(agent) do
    Agent.update(agent, &(&1 + 1))
  end
```

The `count_increased` assertion in the postcondition now guarantees only that
the new value of `get_count/1` is strictly greater than the old value. This
assertion always holds true regardless of the number of concurrent state
updates to the counter.

Although this assertion is not as strong as the `count_incremented_by_1`
assertion in the original version, it is the strongest we can provide given
the possibility of concurrent state updates.

Future versions of Bond may provide stronger support for stateful contracts
in the form of _invariants_ for structs and/or stateful processes, although
this is still a subject of research.

## Documenting contracts

Contracts in the form of preconditions and postconditions are part of the
public interface for a module in the same way that function signatures and
typespecs are. Therefore, it is essential that contracts are included as part
of the documentation for modules and functions.

Bond automatically appends `Preconditions` and `Postconditions` section to the
documentation for any function that defines any preconditions or postconditions
and has a `@doc` attribute. These two generated sections include all of the
assertions specified in the function contract as nicely formatted Elixir code.
Furthermore, contract documentation is generated even if run-time assertion
checking is disabled via configuration. Therefore, it is not necessary to
explicitly document preconditions or postconditions in the `@doc` for a
function unless greater detail is warranted.

The contract documentation is visible not only in documentation generated by
`ex_doc` but also in code editing environments that are able to display
function docs directly in the editor, such as with the `K` command in Vim or
on mouse hover in VS Code.

<!-- README END -->

## Installation

`bond` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 0.8.1"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/bond/Bond.html) and be found at
<https://hexdocs.pm/bond/Bond.html>.
