defmodule McpEx.HTTP do
  @moduledoc "Authenticated, stateless MCP Streamable HTTP with JSON responses."
  import Plug.Conn
  alias McpEx.{Diagnostics, Server}

  def init(context), do: context

  def call(conn, context) do
    conn = do_call(conn, context)
    Diagnostics.count(context, "http." <> to_string(conn.status))
    conn
  end

  defp do_call(conn, context) do
    cond do
      conn.request_path != "/mcp" ->
        send_resp(conn, 404, "Not found")

      not authorized?(conn, context.config.secret) ->
        reject(conn, 401, "Unauthorized")

      not origin_allowed?(conn, context.config.origins) ->
        reject(conn, 403, "Origin not allowed")

      not version_allowed?(conn) ->
        reject(conn, 400, "Unsupported MCP protocol version")

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(405, "")

      not accepts_json?(conn) ->
        reject(conn, 406, "Accept must include application/json and text/event-stream")

      not json_content?(conn) ->
        reject(conn, 415, "Content-Type must be application/json")

      true ->
        receive_message(conn, context)
    end
  end

  defp receive_message(conn, context) do
    case read_body(conn,
           length: context.config.max_bytes,
           read_length: context.config.max_bytes + 1
         ) do
      {:ok, body, conn} when byte_size(body) <= context.config.max_bytes ->
        case Jason.decode(body) do
          {:ok, message} ->
            case Server.handle(message, context) do
              {nil, _} ->
                send_resp(conn, 202, "")

              {response, _} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(response))
            end

          _ ->
            Diagnostics.count(context, "parse_errors")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(Server.error(nil, -32700, "Invalid JSON")))
        end

      {:more, _, conn} ->
        Diagnostics.count(context, "oversize_errors")
        reject(conn, 413, "Request too large")

      {:ok, _, conn} ->
        Diagnostics.count(context, "oversize_errors")
        reject(conn, 413, "Request too large")

      {:error, _} ->
        reject(conn, 400, "Unable to read request")
    end
  end

  defp authorized?(conn, secret) when is_binary(secret) and byte_size(secret) > 0 do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] -> Plug.Crypto.secure_compare(supplied, secret)
      _ -> false
    end
  end

  defp authorized?(_, _), do: false

  defp origin_allowed?(conn, allowed) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin in allowed
      _ -> false
    end
  end

  defp version_allowed?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> true
      [version] -> version in Server.versions()
      _ -> false
    end
  end

  defp accepts_json?(conn) do
    accept = Enum.join(get_req_header(conn, "accept"), ",")

    values =
      accept |> String.split(",") |> Enum.map(&(String.split(&1, ";") |> hd() |> String.trim()))

    "application/json" in values and "text/event-stream" in values
  end

  defp json_content?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        value |> String.downcase() |> String.split(";") |> hd() |> String.trim() ==
          "application/json"

      _ ->
        false
    end
  end

  defp reject(conn, status, message),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"error" => message}))
end
