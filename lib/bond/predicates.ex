defmodule Bond.Predicates do
  @moduledoc """
  Predicate functions and operators that are useful in contract specifications.

  To use the operator versions of the predicates, this module must be imported in the using module.
  """

  @doc """
  Logical exclusive or: is either `p` or `q` true, but not both?

  ## Examples

      iex> xor(true, true)
      false
      iex> xor(true, false)
      true
      iex> xor(false, true)
      true
      iex> xor(false, false)
      false
  """
  @spec xor(boolean, boolean) :: boolean
  def xor(p, q), do: (p || q) && !(p && q)

  @doc """
  Logical exclusive or operator: `p ||| q` means `xor(p, q)`.

  Note that the `|||` operator has higher precedence than many other operators and it may be
  necessary to parenthesize the expressions on either side of the operator to get the
  expected result.

  ## Examples

      iex> true ||| true
      false
      iex> true ||| false
      true
      iex> false ||| true
      true
      iex> false ||| false
      false
      iex> x = 2
      2
      iex> y = 4
      4
      iex> (x - y < 0) ||| (y <= x)
      true
  """
  def p ||| q, do: xor(p, q)

  @doc """
  Logical implication: does `p` imply `q`?

  ## Examples

      iex> implies?(true, true)
      true
      iex> implies?(true, false)
      false
      iex> implies?(false, true)
      true
      iex> implies?(false, false)
      true
  """
  @spec implies?(boolean, boolean) :: boolean
  def implies?(p, q), do: !p || q

  @doc """
  Logical implication operator: `p ~> q` means `implies?(p, q)`.

  Note that the `~>` operator has higher precedence than many other operators and it may be
  necessary to parenthesize the expressions on either side of the operator to get the
  expected result.

  ## Examples

      iex> true ~> true
      true
      iex> true ~> false
      false
      iex> false ~> true
      true
      iex> false ~> false
      true
      iex> x = 2
      2
      iex> y = 4
      4
      iex> (x - y < 0) ~> (y > x)
      true
  """
  def p ~> q, do: implies?(p, q)

  @doc """
  Pattern matching operator: equivalent to `match?(pattern, expression)`.

  ## Examples

      iex> {:ok, %Date{}} <~ Date.new(1974, 6, 6) 
      true
      iex> {:error, _} <~ Date.new(-1, -1, -1)
      true
  """
  defmacro pattern <~ expression do
    quote do
      case unquote(expression) do
        unquote(pattern) -> true
        _unmatched -> false
      end
    end
  end
end
