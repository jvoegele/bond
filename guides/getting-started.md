# Getting Started

This guide provides installation and basic usage information for getting started
quickly with Bond.

Refer to the `Bond` module docs for detailed usage instructions and examples.

## Installation

`bond` can be installed by adding it to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bond, "~> 0.8.3"}
  ]
end
```

## Quick start

Use Bond to define preconditions and postconditions (collectively referred to as
"contracts") to functions.

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
