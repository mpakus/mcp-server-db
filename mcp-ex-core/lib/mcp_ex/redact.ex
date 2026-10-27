defmodule McpEx.Redact do
  @moduledoc "Recursive PII masking and safe JSON representation of database values."
  @columns ~w(email e_mail ssn social_security phone mobile first_name last_name full_name middle_name given_name family_name surname forename maiden_name preferred_name legal_name address street zip postal_code dob date_of_birth credit_card card_number cc_number cvv password passwd pwd api_key secret token ip_address ipaddress)

  def column?(key, config) do
    key = String.downcase(key)

    Enum.any?(@columns ++ config.pii_columns, &String.contains?(key, String.downcase(&1))) or
      Enum.any?(config.pii_patterns, &Regex.match?(&1, key))
  end

  def filter_columns(rows, config) do
    if config.pii, do: Enum.reject(rows, &column?(&1["column_name"], config)), else: rows
  end

  def filter_introspection(rows, config) do
    Enum.reject(rows, fn row ->
      value =
        Enum.find_value(row, &introspection_column/1)

      unless is_binary(value),
        do: raise(ArgumentError, "Cannot safely filter introspection; use MCP resources")

      column?(value, config)
    end)
  end

  defp introspection_column({key, value}) do
    if String.downcase(key) in ["field", "column_name"], do: value
  end

  def apply(value, config), do: value |> normalize() |> walk(config, false)

  def normalize(%Decimal{} = value), do: Decimal.to_string(value)
  def normalize(%Date{} = value), do: Date.to_iso8601(value)
  def normalize(%Time{} = value), do: Time.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(value) when is_struct(value), do: value |> Map.from_struct() |> normalize()

  def normalize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), normalize(v)} end)

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()

  def normalize(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: %{"base64" => Base.encode64(value)})

  def normalize(value)
      when is_integer(value) and (value > 9_007_199_254_740_991 or value < -9_007_199_254_740_991),
      do: to_string(value)

  def normalize(value), do: value

  defp walk(value, %{pii: false}, _), do: value
  defp walk(nil, _, _), do: nil

  defp walk(value, config, sensitive) when is_list(value),
    do: Enum.map(value, &walk(&1, config, sensitive))

  defp walk(value, config, sensitive) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, walk(v, config, sensitive or column?(k, config))} end)

  defp walk(value, config, sensitive) when is_binary(value) do
    cond do
      sensitive ->
        mask(value)

      config.pii_json ->
        case Jason.decode(value) do
          {:ok, parsed} when is_map(parsed) or is_list(parsed) ->
            parsed |> walk(config, false) |> Jason.encode!()

          _ ->
            patterns(value)
        end

      true ->
        patterns(value)
    end
  end

  defp walk(_, _, true), do: "***"
  defp walk(value, _, _), do: value

  defp mask(""), do: ""

  defp mask(value) do
    masked = patterns(value)
    if masked == value, do: "***", else: masked
  end

  defp patterns(value) do
    value =
      Regex.replace(
        ~r/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9-])[A-Za-z0-9.-]*\.([A-Za-z]{2,})/,
        value,
        "\\1***@\\2***.\\3"
      )

    value =
      Regex.replace(~r/(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/, value, fn match ->
        digits = String.replace(match, ~r/[ -]/, "")
        if luhn?(digits), do: "****-****-****-" <> String.slice(digits, -4, 4), else: match
      end)

    value = Regex.replace(~r/(?<!\d)\d{3}-\d{2}-(\d{4})(?!\d)/, value, "***-**-\\1")

    value =
      Regex.replace(
        ~r/(?<!\d)(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?(\d{4})(?!\d)/,
        value,
        "***-***-\\1"
      )

    Regex.replace(~r/(?<!\d)(?:\d{1,3}\.){3}(\d{1,3})(?!\d)/, value, "***.***.***.\\1")
  end

  defp luhn?(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {digit, index}, sum ->
      n = (digit - ?0) * if(rem(index, 2) == 1, do: 2, else: 1)
      sum + if(n > 9, do: n - 9, else: n)
    end)
    |> rem(10) == 0
  end
end
