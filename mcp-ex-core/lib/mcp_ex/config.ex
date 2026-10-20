defmodule McpEx.Config do
  @moduledoc "Validated environment configuration shared by both database servers."
  @operations ~w(insert update delete ddl)

  def load(dialect, env \\ System.get_env()) do
    prefix = if dialect == :mysql, do: "MYSQL", else: "PG"
    host = get(env, prefix <> "_HOST", "127.0.0.1")
    database = get(env, prefix <> "_DB", if(dialect == :mysql, do: nil, else: "postgres"))
    schema = if dialect == :mysql, do: database, else: get(env, "PG_SCHEMA", "public")

    connection = [
      hostname: host,
      port: number(env, prefix <> "_PORT", if(dialect == :mysql, do: 3306, else: 5432), 65_535),
      username: get(env, prefix <> "_USER", if(dialect == :mysql, do: "root", else: "postgres")),
      password: Map.get(env, prefix <> "_PASS", ""),
      database: database,
      pool_size: number(env, prefix <> "_POOL_SIZE", 10, 1000),
      timeout: number(env, prefix <> "_QUERY_TIMEOUT", 30_000),
      connect_timeout: number(env, prefix <> "_CONNECT_TIMEOUT", 10_000),
      ssl: false
    ]

    connection = connection_url(connection, get(env, prefix <> "_CONNECTION_STRING"), dialect)
    connection = Keyword.put(connection, :ssl, tls(env, prefix, connection[:hostname]))
    schema = if dialect == :mysql, do: connection[:database], else: schema
    connection = socket(connection, env, dialect)
    remote = boolean(env, "IS_REMOTE_MCP")
    secret = get(env, "REMOTE_SECRET_KEY")

    if remote and is_nil(secret),
      do: raise(ArgumentError, "REMOTE_SECRET_KEY is required in remote mode")

    %{
      dialect: dialect,
      scheme: if(dialect == :mysql, do: "mysql", else: "postgres"),
      tool: if(dialect == :mysql, do: "mysql_query", else: "pg_query"),
      connection: connection,
      schema: schema,
      timeout: connection[:timeout],
      multi_write: boolean(env, "MULTI_DB_WRITE_MODE"),
      allow: Map.new(@operations, &{&1, boolean(env, "ALLOW_#{String.upcase(&1)}_OPERATION")}),
      permissions:
        Map.new(@operations, &{&1, permissions(env, "SCHEMA_#{String.upcase(&1)}_PERMISSIONS")}),
      pii: boolean(env, "ENABLE_PII_REDACTION"),
      pii_columns: csv(env, "PII_EXTRA_COLUMNS"),
      pii_patterns: patterns(env),
      pii_json: boolean(env, "PII_REDACT_JSON_STRINGS", true),
      pii_star: boolean(env, "PII_ALLOW_SELECT_STAR"),
      pii_references: boolean(env, "PII_ALLOW_REFERENCES"),
      pii_introspection: boolean(env, "PII_ALLOW_INTROSPECTION"),
      pii_block_introspection: boolean(env, "PII_BLOCK_INTROSPECTION"),
      remote: remote,
      secret: secret,
      http_ip: ip(get(env, "MCP_HTTP_HOST", "127.0.0.1")),
      http_port: number(env, "PORT", 3000, 65_535),
      origins: csv(env, "MCP_ALLOWED_ORIGINS"),
      dashboard: boolean(env, "MCP_DASHBOARD"),
      dashboard_dir: McpEx.Diagnostics.directory(env),
      max_bytes: number(env, "MCP_MAX_REQUEST_BYTES", 1_048_576),
      max_response_bytes: number(env, "MCP_MAX_RESPONSE_BYTES", 8_388_608),
      max_sessions: number(env, "MCP_MAX_SESSIONS", 1000),
      max_inflight: number(env, "MCP_MAX_INFLIGHT", 4),
      session_idle_timeout: number(env, "MCP_SESSION_IDLE_TIMEOUT", 300_000),
      request_timeout:
        number(env, "MCP_REQUEST_TIMEOUT", min(connection[:timeout] + 1000, 2_147_483_647))
    }
  end

  def read_only?(config) do
    (is_nil(config.schema) and not config.multi_write) or
      not Enum.any?(@operations, fn op ->
        config.allow[op] or Enum.any?(config.permissions[op], &elem(&1, 1))
      end)
  end

  def allowed?(config, operation, schema) do
    overrides = config.permissions[operation]

    override =
      if config.dialect == :mysql do
        matches =
          Enum.filter(overrides, fn {key, _} ->
            String.downcase(key) == String.downcase(schema || "")
          end)

        if matches == [], do: config.allow[operation], else: Enum.all?(matches, &elem(&1, 1))
      else
        Map.get(overrides, schema, config.allow[operation])
      end

    (not is_nil(config.schema) or config.multi_write) and
      override
  end

  defp get(env, key, default \\ nil) do
    case Map.get(env, key) do
      nil -> default
      "" -> nil
      value -> value
    end
  end

  defp boolean(env, key, default \\ false) do
    case Map.get(env, key) do
      nil -> default
      "true" -> true
      "false" -> false
      _ -> raise ArgumentError, "#{key} must be true or false"
    end
  end

  defp number(env, key, default, maximum \\ 2_147_483_647) do
    case Integer.parse(Map.get(env, key, to_string(default))) do
      {n, ""} when n > 0 and n <= maximum -> n
      _ -> raise ArgumentError, "#{key} must be an integer from 1 to #{maximum}"
    end
  end

  defp csv(env, key),
    do:
      env
      |> Map.get(key, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp permissions(env, key) do
    Map.new(csv(env, key), fn entry ->
      case String.split(entry, ":") do
        [schema, value] when value in ["true", "false"] and schema != "" ->
          {String.trim(schema), value == "true"}

        _ ->
          raise ArgumentError, "#{key} must contain schema:true or schema:false entries"
      end
    end)
  end

  defp patterns(env) do
    env
    |> Map.get("PII_EXTRA_COLUMN_PATTERNS", "")
    |> String.split(";", trim: true)
    |> Enum.map(&Regex.compile!(&1, "i"))
  end

  defp ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> raise ArgumentError, "MCP_HTTP_HOST must be an IP address"
    end
  end

  defp socket(connection, env, :mysql) do
    case get(env, "MYSQL_SOCKET_PATH") do
      nil -> Keyword.put(connection, :protocol, :tcp)
      path -> connection |> Keyword.put(:protocol, :socket) |> Keyword.put(:socket, path)
    end
  end

  defp socket(connection, env, :pg) do
    case get(env, "PG_SOCKET_PATH") do
      nil -> connection
      path -> Keyword.put(connection, :socket_dir, path)
    end
  end

  defp connection_url(connection, nil, _), do: connection

  defp connection_url(connection, value, dialect) do
    uri = URI.parse(value)
    schemes = if dialect == :mysql, do: ["mysql"], else: ["postgres", "postgresql"]

    if uri.scheme not in schemes or is_nil(uri.host) or not is_nil(uri.query) or
         not is_nil(uri.fragment),
       do:
         raise(ArgumentError, "Connection string must be a database URL without query parameters")

    [user | password] = String.split(uri.userinfo || "", ":", parts: 2)
    database = (uri.path || "") |> String.trim_leading("/") |> URI.decode()
    if String.contains?(database, "/"), do: raise(ArgumentError, "Invalid database URL path")

    connection
    |> Keyword.put(:hostname, uri.host)
    |> Keyword.put(:port, uri.port || connection[:port])
    |> Keyword.put(:username, URI.decode(user))
    |> Keyword.put(:password, URI.decode(List.first(password) || ""))
    |> Keyword.put(:database, if(database == "", do: nil, else: database))
  end

  defp tls(env, prefix, host) do
    cert = get(env, prefix <> "_SSL_CERT")
    key = get(env, prefix <> "_SSL_KEY")

    if is_nil(cert) != is_nil(key),
      do: raise(ArgumentError, "TLS client certificate and key must be configured together")

    if boolean(env, prefix <> "_SSL") do
      verify = boolean(env, prefix <> "_SSL_REJECT_UNAUTHORIZED", true)

      trust =
        case get(env, prefix <> "_SSL_CA") do
          nil -> [cacerts: :public_key.cacerts_get()]
          file -> [cacertfile: pem_file(file)]
        end

      client = if cert, do: [certfile: pem_file(cert), keyfile: pem_file(key)], else: []

      [
        verify: if(verify, do: :verify_peer, else: :verify_none),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ trust ++ client
    else
      false
    end
  end

  defp pem_file(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        if :public_key.pem_decode(content) == [], do: raise(ArgumentError, "Invalid TLS PEM file")
        String.to_charlist(path)

      _ ->
        raise ArgumentError, "TLS PEM file must exist and be nonempty"
    end
  end
end
