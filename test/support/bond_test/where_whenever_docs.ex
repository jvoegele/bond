defmodule BondTest.WhereWheneverDocs do
  @moduledoc "Fixture exercising generated docs for `where`/`whenever` binding groups (#47)."
  use Bond
  import Bond.Predicates

  @doc "Builds an ok-tuple of urls."
  @post whenever({:ok, %{urls: urls}} <- result),
    url_count: length(urls) > 0,
    all_https: forall(u <- urls, String.starts_with?(u, "https"))
  @post where({:ok, payload} = result), tagged: is_map(payload)
  def run(list), do: {:ok, %{urls: list}}
end
