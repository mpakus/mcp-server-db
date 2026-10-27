defmodule McpEx.Pg.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex_pg,
      version: "0.2.0",
      elixir: "~> 1.18",
      escript: [main_module: McpEx.Pg.CLI, name: "mcp-ex-pg", emu_args: "-noinput"],
      deps: [
        {:mcp_ex_core, path: "../mcp-ex-core"},
        {:postgrex, "~> 0.22.0"},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :ssl]]
end
