defmodule McpEx.Core.MixProject do
  use Mix.Project

  def project do
    [app: :mcp_ex_core, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :ssl]]

  defp deps do
    [{:jason, "~> 1.4"}, {:bandit, "~> 1.13.1"}, {:plug, "~> 1.16"}, {:decimal, "~> 3.1.2"}]
  end
end
