# Bond

Design By Contract for Elixir.

## About this library

Bond provides support for contract programming (also known as
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

## Installation

`bond` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm/bond) and be found at
<https://hexdocs.pm/bond>.
