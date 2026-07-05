defmodule SqlitesWeb.Hrana.Stmt do
  @moduledoc """
  Hrana statement execution shared by the WebSocket handler and the
  HTTP pipeline: SQL resolution (inline or stored `sql_id`), value
  decoding/encoding, positional and named args, and the per-database
  edge checks (transaction-control rejection, rate limit, query
  timeout) applied uniformly.
  """

  alias Sqlites.DataPlane

  @transactions_message "interactive transactions (BEGIN/COMMIT/ROLLBACK/SAVEPOINT) are not " <>
                          "supported; statements run in autocommit mode"

  @spec execute(map(), map(), Sqlites.ControlPlane.Database.t(), Sqlites.Limits.t()) ::
          {:ok, map()} | {:error, String.t()}
  def execute(stmt, sqls, database, limits) do
    with {:ok, sql} <- resolve_sql(stmt, sqls),
         :ok <- check_statement(sql),
         :ok <- check_rate_limit(database, limits),
         {:ok, args} <- decode_args(stmt) do
      run(sql, args, database, limits)
    end
  end

  @spec batch(map(), map(), Sqlites.ControlPlane.Database.t(), Sqlites.Limits.t()) :: map()
  def batch(%{"steps" => steps}, sqls, database, limits) do
    step_results =
      Enum.map(steps, fn %{"stmt" => stmt} -> execute(stmt, sqls, database, limits) end)

    %{
      step_results:
        Enum.map(step_results, fn
          {:ok, result} -> result
          {:error, _} -> nil
        end),
      step_errors:
        Enum.map(step_results, fn
          {:ok, _} -> nil
          {:error, message} -> %{message: message}
        end)
    }
  end

  @spec describe(map(), map(), Sqlites.ControlPlane.Database.t(), Sqlites.Limits.t()) ::
          {:ok, map()} | {:error, String.t()}
  def describe(request, sqls, database, limits) do
    with {:ok, sql} <- resolve_sql(request, sqls),
         :ok <- check_rate_limit(database, limits) do
      case DataPlane.describe(database.id, sql, query_timeout(limits)) do
        {:ok, result} ->
          {:ok,
           %{
             params: List.duplicate(%{name: nil}, result.param_count),
             cols: Enum.map(result.columns, &%{name: &1}),
             is_explain: false,
             is_readonly: not Sqlites.DataPlane.Sql.write?(sql)
           }}

        {:error, reason} ->
          {:error, format_reason(reason)}
      end
    end
  end

  @spec sequence(map(), map(), Sqlites.ControlPlane.Database.t(), Sqlites.Limits.t()) ::
          :ok | {:error, String.t()}
  def sequence(request, sqls, database, limits) do
    with {:ok, sql} <- resolve_sql(request, sqls),
         :ok <- check_script(sql),
         :ok <- check_rate_limit(database, limits) do
      case DataPlane.sequence(database.id, sql, query_timeout(limits)) do
        :ok -> :ok
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end
  end

  defp run(sql, args, database, limits) do
    case DataPlane.query(database.id, sql, args, query_timeout(limits)) do
      {:ok, result} ->
        {:ok,
         %{
           cols: Enum.map(result.columns, &%{name: &1}),
           rows: Enum.map(result.rows, fn row -> Enum.map(row, &encode_value/1) end),
           affected_row_count: result.num_changes,
           last_insert_rowid: to_string(result.last_insert_rowid)
         }}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp resolve_sql(%{"sql" => sql}, _sqls) when is_binary(sql), do: {:ok, sql}

  defp resolve_sql(%{"sql_id" => sql_id}, sqls) do
    case Map.fetch(sqls, sql_id) do
      {:ok, sql} -> {:ok, sql}
      :error -> {:error, "unknown sql_id #{sql_id}"}
    end
  end

  defp resolve_sql(_request, _sqls), do: {:error, "stmt requires sql or sql_id"}

  defp check_statement(sql) do
    if Sqlites.DataPlane.Sql.transaction_control?(sql) do
      {:error, @transactions_message}
    else
      :ok
    end
  end

  defp check_script(sql) do
    sql
    |> String.split(";")
    |> Enum.all?(fn segment -> not Sqlites.DataPlane.Sql.transaction_control?(segment) end)
    |> case do
      true -> :ok
      false -> {:error, @transactions_message}
    end
  end

  defp check_rate_limit(database, limits) do
    if Sqlites.RateLimiter.allow?(database.id, limits.rate_limit_rps) do
      :ok
    else
      {:error, "database rate limit exceeded"}
    end
  end

  defp decode_args(%{"args" => args, "named_args" => named})
       when args != [] and is_list(named) and named != [] do
    {:error, "mixing positional and named args is not supported"}
  end

  defp decode_args(%{"named_args" => named}) when is_list(named) and named != [] do
    {:ok,
     Map.new(named, fn %{"name" => name, "value" => value} -> {name, decode_value(value)} end)}
  end

  defp decode_args(stmt) do
    {:ok, Enum.map(stmt["args"] || [], &decode_value/1)}
  end

  defp query_timeout(limits) do
    limits.query_timeout_ms || :timer.seconds(30)
  end

  defp format_reason(:query_timeout), do: "query timed out"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp decode_value(%{"type" => "null"}), do: nil

  defp decode_value(%{"type" => "integer", "value" => value}) when is_binary(value),
    do: String.to_integer(value)

  defp decode_value(%{"type" => "integer", "value" => value}), do: value
  defp decode_value(%{"type" => "float", "value" => value}), do: value
  defp decode_value(%{"type" => "text", "value" => value}), do: value

  defp decode_value(%{"type" => "blob", "base64" => base64}),
    do: {:blob, Base.decode64!(base64, padding: false)}

  defp encode_value(nil), do: %{type: "null"}
  defp encode_value(value) when is_integer(value), do: %{type: "integer", value: to_string(value)}
  defp encode_value(value) when is_float(value), do: %{type: "float", value: value}

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value) do
      %{type: "text", value: value}
    else
      %{type: "blob", base64: Base.encode64(value, padding: false)}
    end
  end
end
