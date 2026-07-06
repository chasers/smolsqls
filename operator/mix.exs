defmodule SmolsqlsOperator.MixProject do
  use Mix.Project

  def project do
    [
      app: :smolsqls_operator,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SmolsqlsOperator.Application, []}
    ]
  end

  defp deps do
    [
      {:bonny, "~> 1.4"},
      {:postgrex, "~> 0.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format", "credo --strict", "test"],
      ci: [
        "hex.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "deps.audit"
      ]
    ]
  end
end
