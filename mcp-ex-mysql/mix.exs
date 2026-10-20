defmodule McpEx.Mysql.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex_mysql,
      version: "0.1.0",
      elixir: "~> 1.18",
      escript: [main_module: McpEx.Mysql.CLI, name: "mcp-ex-mysql", emu_args: "-noinput"],
      deps: [{:mcp_ex_core, path: "../mcp-ex-core"}, {:myxql, "~> 0.9.0"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :ssl]]
end
