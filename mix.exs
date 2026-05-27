defmodule Bond.MixProject do
  use Mix.Project

  @version "0.17.3"
  @source_url "https://github.com/jvoegele/bond"

  def project do
    [
      app: :bond,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_add_apps: [:stream_data, :mix, :ex_unit]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],

      # Hex
      description: "Design By Contract (DbC) for Elixir",
      package: package(),

      # Docs
      name: "Bond",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ~w[lib test/support]
  defp elixirc_paths(_), do: ~w[lib]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.0"},
      # `stream_data` is optional: users who want property-based testing via
      # `Bond.PropertyTest` add it to their own deps; everyone else doesn't pay the cost.
      # Marked `optional: true` so it's available for Bond's own test suite (and to lib/
      # references guarded by `Code.ensure_loaded?/1`) without becoming a transitive dep
      # for downstream apps.
      {:stream_data, "~> 0.6", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      name: :bond,
      files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", ".formatter.exs"],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Bond",
      extras: [
        {"LICENSE", [title: "License"]},
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/faq.md",
        "guides/about.md",
        "guides/history.md",
        "guides/contracts-and-concurrency.md"
      ],
      filter_modules: fn _module, meta ->
        # This allows us to tag modules as internal and exclude them from the API docs as follows:
        #   @moduledoc internal: true
        not Map.get(meta, :internal, false)
      end
    ]
  end
end
