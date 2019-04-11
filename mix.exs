defmodule Gruntle.MixProject do
  use Mix.Project

  def project do
    [
      app: :gruntle,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Gruntle.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gen_stage, "~> 0.14.1"},
      {:kafka_ex, git: "https://github.com/gerbal/kafka_ex", branch: "custom-genconsumer"},
      # kafka_ex_gen_stage_consumer currently depends on an alternative kafka_ex branch
      # {:kafka_ex,
      # git: "https://github.com/gerbal/kafka_ex",
      # ref: "0eb40dd345ecbc84f9d2b2427cd5e4a6873032f2",
      # override: true},
      {:kafka_ex_gen_stage_consumer, git: "https://github.com/gerbal/kafka_ex_gen_stage_consumer"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
