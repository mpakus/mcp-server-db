defmodule McpEx.HTTP do
  @moduledoc "Authenticated MCP Streamable HTTP with supervised sessions and JSON responses."
  import Plug.Conn
  alias McpEx.{Diagnostics, Server, Session}

  def init(context), do: context

  def call(%{path_info: ["dashboard" | _]} = conn, context),
    do: McpEx.Dashboard.call(conn, context)

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

      conn.method == "DELETE" ->
        with_session(conn, context, fn pid ->
          Session.close(pid)
          send_resp(conn, 204, "")
        end)

      conn.method == "GET" ->
        with_session(conn, context, fn _ ->
          conn |> put_resp_header("allow", "POST, DELETE") |> send_resp(405, "")
        end)

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST, DELETE") |> send_resp(405, "")

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
            dispatch(conn, message, context)

          _ ->
            Diagnostics.count(context, "parse_errors")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(Server.error(nil, -32_700, "Invalid JSON")))
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

  defp dispatch(conn, message, context) do
    if get_req_header(conn, "mcp-session-id") == [] and
         is_map(message) and message["method"] == "initialize" do
      # Validate before allocating a session; malformed initialization cannot consume slots.
      case Server.handle(message, context, :new) do
        {%{"result" => result} = response, :initializing} ->
          case Session.open(context, nil, result["protocolVersion"]) do
            {:ok, id, _pid} ->
              conn
              |> put_resp_header("mcp-session-id", id)
              |> respond({:ok, Server.encode(response, context.config.max_response_bytes)})

            {:error, :max_children} ->
              reject(conn, 503, "Session capacity reached")
          end

        {response, _} ->
          respond(conn, {:ok, Server.encode(response, context.config.max_response_bytes)})
      end
    else
      with_session(conn, context, fn pid ->
        respond(
          conn,
          Session.request(pid, message, List.first(get_req_header(conn, "mcp-protocol-version")))
        )
      end)
    end
  end

  defp with_session(conn, context, fun) do
    case get_req_header(conn, "mcp-session-id") do
      [id] when byte_size(id) == 32 ->
        case Session.lookup(context, id) do
          {:ok, pid} -> fun.(pid)
          {:error, :not_found} -> reject(conn, 404, "Session not found; initialize again")
        end

      [] ->
        reject(conn, 400, "MCP-Session-Id is required")

      _ ->
        reject(conn, 404, "Invalid MCP-Session-Id")
    end
  end

  defp respond(conn, {:ok, nil}), do: send_resp(conn, 202, "")

  defp respond(conn, {:ok, response}),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, response)

  defp respond(conn, {:error, :version}),
    do: reject(conn, 400, "Protocol version differs from session")

  defp respond(conn, {:error, :closed}), do: reject(conn, 404, "Session closed; initialize again")

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
