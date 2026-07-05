defmodule Sqlites.ReadModel.Snapshot do
  @moduledoc """
  Bulk-loads the read model from Postgres using `COPY ... TO STDOUT`
  streamed through the SQL adapter — wire-speed rows straight into ETS
  with no Ecto struct materialization on the way. Runs on first boot
  and whenever the replication slot has been invalidated.

  COPY text format is parsed by tab-splitting; the replicated columns
  are constrained (uuids, url-safe tokens, validated slugs/names,
  POSIX paths) and cannot contain tabs, newlines, or backslashes.
  """

  alias Sqlites.ReadModel
  alias Sqlites.ReadModel.Row
  alias Sqlites.Repo

  @spec load() :: :ok
  def load do
    {:ok, :ok} =
      Repo.transaction(
        fn ->
          load_table(:tenants, Row.tenant_columns(), &Row.build_tenant/1, &ReadModel.put_tenant/1)

          load_table(
            :databases,
            Row.database_columns(),
            &Row.build_database/1,
            &ReadModel.put_database/1
          )

          load_table(
            :tenant_api_keys,
            Row.tenant_api_key_columns(),
            &Row.build_tenant_api_key/1,
            &ReadModel.put_tenant_api_key/1
          )

          load_table(
            :database_tokens,
            Row.database_token_columns(),
            &Row.build_database_token/1,
            &ReadModel.put_database_token/1
          )

          :ok
        end,
        timeout: :timer.minutes(5)
      )

    :ok
  end

  defp load_table(table, columns, build, put) do
    sql = "COPY (SELECT #{Enum.join(columns, ", ")} FROM #{table}) TO STDOUT"

    Repo
    |> Ecto.Adapters.SQL.stream(sql, [], max_rows: 5_000)
    |> Stream.flat_map(& &1.rows)
    |> Enum.each(fn line ->
      line
      |> parse_line(columns)
      |> build.()
      |> put.()
    end)
  end

  defp parse_line(line, columns) do
    values =
      line
      |> String.trim_trailing("\n")
      |> String.split("\t")
      |> Enum.map(fn
        "\\N" -> nil
        value -> value
      end)

    Enum.zip(columns, values) |> Map.new()
  end
end
