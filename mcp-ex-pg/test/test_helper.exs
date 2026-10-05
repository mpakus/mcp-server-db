ExUnit.start(
  exclude: if(System.get_env("MCP_INTEGRATION") == "true", do: [], else: [:integration])
)
