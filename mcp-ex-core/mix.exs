defmodule McpEx.Core.MixProject do
  use Mix.Project

  def project do
    [app: :mcp_ex_core, version: "0.2.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :ssl]]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.14.0"},
      {:plug, "~> 1.16"},
      {:decimal, "~> 3.2.0"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}
    ]
  end
end
