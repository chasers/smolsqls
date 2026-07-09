defmodule SmolsqlsWeb.Hrana.Stmt do
  @moduledoc """
  Hrana statement execution shared by the WebSocket handler and the
  HTTP pipeline: SQL resolution (inline or stored `sql_id`), value
  decoding/encoding, positional and named args, and the per-database
  edge checks (rate limit, query timeout) applied uniformly.

  The context map carries `database`, `limits`, `owner` (the writer
  lease identity — the WebSocket process), and `allow_transactions`.
  Transaction-control statements pass through to the server's writer
  lease when allowed (the WebSocket path) and are rejected cleanly
  when not (the stateless HTTP pipeline).
  """

  require Logger

  alias Smolsqls.DataPlane
  alias SmolsqlsWeb.Api.ErrorCode

  @type ctx :: %{
          database: Smolsqls.ControlPlane.Database.t(),
          limits: Smolsqls.Limits.t(),
          owner: pid() | nil,
          allow_transactions: boolean()
        }

  @transactions_message "interactive transactions (BEGIN/COMMIT/ROLLBACK/SAVEPOINT) are not " <>
                          "supported here; statements run in autocommit mode"

  @spec execute(map(), map(), ctx()) :: {:ok, map()} | {:error, String.t()}
  def execute(stmt, sqls, ctx) do
    with {:ok, sql} <- resolve_sql(stmt, sqls),
         :ok <- check_statement(sql, ctx),
         :ok <- check_rate_limit(ctx),
         {:ok, args} <- decode_args(stmt) do
      run(sql, args, ctx)
    end
  end

  @doc """
  Runs a Hrana batch: each step executes only when its `condition`
  holds against the outcomes of prior steps (`ok`/`error`/`and`/`or`/
  `not`/`is_autocommit`, per the Hrana spec). Steps whose condition is
  false are skipped — neither a result nor an error — which is how
  libSQL clients wrap statements in `BEGIN`/`COMMIT`/`ROLLBACK` for
  atomic reads and writes. A missing condition always runs.
  """
  @spec batch(map(), map(), ctx()) :: map()
  def batch(%{"steps" => steps}, sqls, ctx) do
    outcomes =
      steps
      |> Enum.reduce([], fn step, prior ->
        outcome =
          if condition_met?(Map.get(step, "condition"), Enum.reverse(prior), ctx) do
            execute(step["stmt"], sqls, ctx)
          else
            :skipped
          end

        [outcome | prior]
      end)
      |> Enum.reverse()

    %{
      step_results:
        Enum.map(outcomes, fn
          {:ok, result} -> result
          _ -> nil
        end),
      step_errors:
        Enum.map(outcomes, fn
          {:error, message} -> %{message: message}
          _ -> nil
        end)
    }
  end

  defp condition_met?(nil, _prior, _ctx), do: true

  defp condition_met?(%{"type" => "ok", "step" => step}, prior, _ctx),
    do: match?({:ok, _}, Enum.at(prior, step))

  defp condition_met?(%{"type" => "error", "step" => step}, prior, _ctx),
    do: match?({:error, _}, Enum.at(prior, step))

  defp condition_met?(%{"type" => "not", "cond" => cond}, prior, ctx),
    do: not condition_met?(cond, prior, ctx)

  defp condition_met?(%{"type" => "and", "conds" => conds}, prior, ctx),
    do: Enum.all?(conds, &condition_met?(&1, prior, ctx))

  defp condition_met?(%{"type" => "or", "conds" => conds}, prior, ctx),
    do: Enum.any?(conds, &condition_met?(&1, prior, ctx))

  defp condition_met?(%{"type" => "is_autocommit"}, _prior, ctx),
    do: DataPlane.autocommit?(ctx.database.id, ctx.owner)

  defp condition_met?(_unknown, _prior, _ctx), do: true

  @spec describe(map(), map(), ctx()) :: {:ok, map()} | {:error, String.t()}
  def describe(request, sqls, ctx) do
    with {:ok, sql} <- resolve_sql(request, sqls),
         :ok <- check_rate_limit(ctx) do
      case DataPlane.describe(ctx.database.id, sql, query_timeout(ctx.limits), ctx.owner) do
        {:ok, result} ->
          {:ok,
           %{
             params: List.duplicate(%{name: nil}, result.param_count),
             cols: Enum.map(result.columns, &%{name: &1}),
             is_explain: false,
             is_readonly: not Smolsqls.DataPlane.Sql.write?(sql)
           }}

        {:error, reason} ->
          {:error, format_reason(reason)}
      end
    end
  end

  @spec sequence(map(), map(), ctx()) :: :ok | {:error, String.t()}
  def sequence(request, sqls, ctx) do
    with {:ok, sql} <- resolve_sql(request, sqls),
         :ok <- check_script(sql, ctx),
         :ok <- check_rate_limit(ctx) do
      case DataPlane.sequence(ctx.database.id, sql, query_timeout(ctx.limits), ctx.owner) do
        :ok -> :ok
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end
  end

  defp run(sql, args, ctx) do
    case DataPlane.query(ctx.database.id, sql, args, query_timeout(ctx.limits), ctx.owner) do
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

  defp check_statement(_sql, %{allow_transactions: true}), do: :ok

  defp check_statement(sql, _ctx) do
    if Smolsqls.DataPlane.Sql.transaction_control?(sql) do
      {:error, @transactions_message}
    else
      :ok
    end
  end

  defp check_script(_sql, %{allow_transactions: true}), do: :ok

  defp check_script(sql, _ctx) do
    sql
    |> String.split(";")
    |> Enum.all?(fn segment -> not Smolsqls.DataPlane.Sql.transaction_control?(segment) end)
    |> case do
      true -> :ok
      false -> {:error, @transactions_message}
    end
  end

  defp check_rate_limit(ctx) do
    if Smolsqls.RateLimiter.allow?(ctx.database.id, ctx.limits.rate_limit_rps) do
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

  defp format_reason(reason) do
    {status, code, message} = ErrorCode.classify(reason)

    if ErrorCode.loggable?(status) do
      Logger.error(
        "hrana error code=#{code} request_id=#{Logger.metadata()[:request_id]} " <>
          "reason=#{inspect(reason, printable_limit: 2048, limit: 50)}"
      )
    end

    message
  end

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
