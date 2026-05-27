defmodule ContractConsumer.MixProject do
  use Mix.Project

  # Standalone "downstream consumer" project. It depends on Bond as a path
  # dependency and exists to verify that the code Bond *generates into a using
  # module* (defoverridable wrapper clauses, lifted assertion defps, invariant
  # checks) compiles without warnings and passes Dialyzer in a real consumer —
  # the thing Bond's own test suite cannot prove about itself. See
  # `.github/workflows/ci.yml` (the `downstream` job) and issue #2.
  def project do
    [
      app: :contract_consumer,
      version: "0.1.0",
      elixir: "~> 1.14",
      deps: deps(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_add_apps: [:bond]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:bond, path: "../.."},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
