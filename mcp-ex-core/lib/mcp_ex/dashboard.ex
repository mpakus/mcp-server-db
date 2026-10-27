defmodule McpEx.Dashboard do
  @moduledoc "Read-only browser view of this server's private diagnostic snapshot."
  import Plug.Conn

  @html_path Path.expand("../../priv/dashboard.html", __DIR__)
  @script_path Path.expand("../../priv/dashboard.js", __DIR__)
  @external_resource @html_path
  @external_resource @script_path
  @html File.read!(@html_path)
  @script File.read!(@script_path)

  def init(context), do: context

  def call(conn, context) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      )

    cond do
      is_nil(Map.get(context, :dashboard_token)) or is_nil(Map.get(context, :diagnostics)) ->
        send_resp(conn, 404, "Not found")

      conn.request_path not in ["/dashboard", "/dashboard/app.js", "/dashboard/data"] ->
        send_resp(conn, 404, "Not found")

      conn.method != "GET" ->
        conn |> put_resp_header("allow", "GET") |> send_resp(405, "Method not allowed")

      conn.request_path == "/dashboard" ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, @html)

      conn.request_path == "/dashboard/app.js" ->
        conn |> put_resp_content_type("text/javascript") |> send_resp(200, @script)

      not authorized?(conn, context.dashboard_token) ->
        send_resp(conn, 401, "Open the private dashboard link printed by this server")

      true ->
        snapshot(conn, context)
    end
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] -> Plug.Crypto.secure_compare(supplied, token)
      _ -> false
    end
  end

  defp snapshot(conn, context) do
    case McpEx.Monitor.inspect_instances(
           context.config.dashboard_dir,
           context.config.dialect,
           context.diagnostics.instance_id
         ) do
      {:ok, [instance]} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(instance))

      _ ->
        send_resp(conn, 503, "Diagnostic snapshot unavailable; retrying")
    end
  end
end
