defmodule Beamflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamflow,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Docs
      name: "Beamflow",
      source_url: "https://github.com/tsardinasGitHub/beamflow",
      homepage_url: "https://github.com/tsardinasGitHub/beamflow",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling, :underspecs]
      ],

      # Test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
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
      mod: {Beamflow.Application, []},
      extra_applications: [:logger, :runtime_tools, :mnesia]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Phoenix & Web
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_view, "~> 0.20.17"},
      {:phoenix_live_dashboard, "~> 0.8.4"},

      # HTTP & JSON
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.4.0"},
      {:gettext, "~> 0.24"},
      {:elixir_uuid, "~> 1.2"},

      # Database - Amnesia (Mnesia DSL)
      {:amnesia, "~> 0.2.8"},

      # Telemetry & Monitoring
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Assets
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons, "~> 0.5"},

      # Development & Testing
      {:floki, ">= 0.36.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:dotenvy, "~> 0.8.0", only: [:dev, :test]},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind beamflow", "esbuild beamflow"],
      "assets.deploy": [
        "tailwind beamflow --minify",
        "esbuild beamflow --minify",
        "phx.digest"
      ],
      test: ["test"],
      quality: ["format --check-formatted", "credo --strict", "dialyzer", "sobelow --config"],
      "quality.fix": ["format", "credo --strict --fix-all"],
      security: ["sobelow --config"]
    ]
  end
end
