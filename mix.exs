defmodule Bond.MixProject do
  use Mix.Project

  @version "1.19.0"
  @source_url "https://github.com/jvoegele/bond"

  def project do
    [
      app: :bond,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_add_apps: [:stream_data, :mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      test_coverage: [tool: ExCoveralls],

      # Hex
      description: "Design by Contract (DbC) for Elixir",
      package: package(),

      # Docs
      name: "Bond",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
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
      # Marked `optional: true` so it's available for Bond's own test suite without becoming
      # a transitive dep for downstream apps.
      #
      # The lib/ references are guarded two ways, because one guard is not enough: at runtime
      # by `Code.ensure_loaded?/1`, and at compile time by `@compile {:no_warn_undefined,
      # StreamData}` in the three `Bond.PropertyTest` modules. The runtime guard alone still
      # let the compiler resolve the remote calls and warn — see issue #76.
      {:stream_data, "~> 1.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test},
      # `norm` is used only by test/bond/norm_compat_test.exs to verify Bond's
      # `Kernel.@/1` override coexists with another library that also overrides
      # `@/1`. Norm uses the identical technique to Bond (import Kernel exc. @,
      # specific clause + catch-all forwarding), so it's the natural conflict
      # counterpart. Not a transitive dep — only_test.
      {:norm, "~> 0.13", only: :test}
    ]
  end

  defp package do
    [
      name: :bond,
      # `guides` ships with the package: since the reference moved off the landing page
      # (1.14.0), the README and moduledoc point at `guides/*.md` for most of the detail,
      # and those links are dead in the tarball if the directory is left out. HexDocs is
      # built from the working tree at publish time and was never affected.
      files: [
        "lib",
        "guides",
        # Agent-facing rules, consumed by `usage_rules` (https://hex.pm/packages/usage_rules):
        # `usage-rules.md` is the main file, `usage-rules/*.md` are sub-rules referenced as
        # `"bond:testing"` / `"bond:inheritance"`, and `usage-rules/skills/` holds a pre-built
        # skill users pull in with `skills: [package_skills: [:bond]]`. Both paths must be listed
        # or the files are absent from the tarball and `mix usage_rules.sync` finds nothing.
        "usage-rules.md",
        "usage-rules",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        ".formatter.exs"
      ],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "Bond",
      extras: [
        {"LICENSE", [title: "License"]},
        "CHANGELOG.md",
        # Guides are ordered by the questions a reader asks, in the order they
        # ask them: learn it, write it, know what to say in it, say it soundly,
        # then the larger features, then the operational concerns — of which wiring the
        # agent-facing rules into a downstream project is the last. Reference is for lookup rather
        # than reading, so it sits after the narrative path.
        "guides/getting-started.md",
        "guides/writing-contracts.md",
        "guides/what-contracts-say.md",
        "guides/writing-sound-assertions.md",
        "guides/invariants.md",
        "guides/reusable-contracts.md",
        "guides/contract-inheritance.md",
        "guides/contracts-and-concurrency.md",
        "guides/testing-contracts.md",
        "guides/configuration.md",
        "guides/overhead.md",
        "guides/telemetry.md",
        "guides/ai-coding-agents.md",
        "guides/cheatsheet.cheatmd",
        "guides/faq.md",
        # Agent-facing, but published here too: the README links to it, and a reader
        # browsing HexDocs should be able to find what their agent is being told.
        # Only the main file — the sub-rules and the skill are synced, not browsed. Installing
        # any of it is guides/ai-coding-agents.md, which is written for a person.
        "usage-rules.md",
        "guides/public-api.md",
        "guides/stability.md",
        "guides/about.md",
        "guides/history.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/writing-contracts.md",
          "guides/what-contracts-say.md",
          "guides/writing-sound-assertions.md",
          "guides/invariants.md",
          "guides/reusable-contracts.md",
          "guides/contract-inheritance.md",
          "guides/contracts-and-concurrency.md",
          "guides/testing-contracts.md",
          "guides/configuration.md",
          "guides/overhead.md",
          "guides/telemetry.md",
          "guides/ai-coding-agents.md"
        ],
        Reference: [
          "guides/cheatsheet.cheatmd",
          "guides/faq.md",
          "usage-rules.md",
          "guides/public-api.md",
          "guides/stability.md"
        ],
        About: [
          "guides/about.md",
          "guides/history.md"
        ]
      ],
      # Bond's first Mix task. Without a group it sorts in among the
      # library modules, where `Mix.Tasks.Bond.Audit` reads as an API module
      # rather than something you run.
      groups_for_modules: [
        "Mix tasks": [
          Mix.Tasks.Bond.Audit
        ]
      ],
      filter_modules: fn _module, meta ->
        # This allows us to tag modules as internal and exclude them from the API docs as follows:
        #   @moduledoc internal: true
        not Map.get(meta, :internal, false)
      end
    ]
  end
end
