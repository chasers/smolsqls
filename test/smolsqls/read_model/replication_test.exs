defmodule Smolsqls.ReadModel.ReplicationTest do
  @moduledoc """
  Drives the real WAL feed: writes are committed through a raw Postgrex
  connection (outside the sandbox), streamed through the logical
  replication slot, decoded from pgoutput, and asserted against the
  cache. Skipped when the Postgres server does not have
  `wal_level=logical`.

  What the feed must and must not do: it updates and deletes rows this
  node already holds, and it never populates one it does not — otherwise
  the cache grows back into the full replica this design replaced.
  """

  use ExUnit.Case, async: false

  alias Smolsqls.ControlPlane.{Database, DatabaseToken}
  alias Smolsqls.ReadModel
  alias Smolsqls.Wait

  setup_all do
    conn = start_raw_conn!()
    %{rows: [[wal_level]]} = Postgrex.query!(conn, "SHOW wal_level", [])
    GenServer.stop(conn)

    if wal_level == "logical", do: :ok, else: :skip
  end

  setup do
    conn = start_raw_conn!()
    tenant_id = Ecto.UUID.generate()
    database_id = Ecto.UUID.generate()

    on_exit(fn ->
      cleanup = start_raw_conn!()

      Postgrex.query!(cleanup, "DELETE FROM databases WHERE id = $1::uuid", [
        Ecto.UUID.dump!(database_id)
      ])

      Postgrex.query!(cleanup, "DELETE FROM tenants WHERE id = $1::uuid", [
        Ecto.UUID.dump!(tenant_id)
      ])

      Postgrex.query!(
        cleanup,
        "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = $1",
        [Smolsqls.ReadModel.Replication.slot_name()]
      )

      GenServer.stop(cleanup)
    end)

    start_supervised!({ReadModel, probe: fn -> :ok end, sweep_interval_ms: 60_000})
    start_supervised!(Smolsqls.ReadModel.Replication)

    %{conn: conn, tenant_id: tenant_id, database_id: database_id}
  end

  test "updates and deletes flow from the WAL; inserts never populate",
       %{conn: conn, tenant_id: tenant_id, database_id: database_id} do
    token = "tok_repl_#{System.unique_integer([:positive])}"
    token_hash = Smolsqls.Secrets.hash(token)

    insert_tenant(conn, tenant_id)
    insert_database(conn, database_id, tenant_id)
    insert_token(conn, database_id, token, token_hash)

    :ok = ReadModel.put(:databases, %Database{id: database_id, tenant_id: tenant_id})

    Postgrex.query!(
      conn,
      "UPDATE databases SET node = 'claimed@somewhere', updated_at = now() WHERE id = $1::uuid",
      [Ecto.UUID.dump!(database_id)]
    )

    Wait.until(fn ->
      match?({:ok, %{node: "claimed@somewhere"}}, ReadModel.peek(:databases, database_id))
    end)

    assert ReadModel.peek(:database_tokens, token_hash) == :absent
    assert ReadModel.peek(:tenants, tenant_id) == :absent

    :ok =
      ReadModel.put(:database_tokens, %DatabaseToken{
        id: Ecto.UUID.generate(),
        database_id: database_id,
        token_hash: token_hash,
        enabled: true
      })

    Postgrex.query!(
      conn,
      "UPDATE database_tokens SET enabled = false, updated_at = now() WHERE token_hash = $1",
      [token_hash]
    )

    Wait.until(fn ->
      match?({:ok, %{enabled: false}}, ReadModel.peek(:database_tokens, token_hash))
    end)

    Postgrex.query!(conn, "DELETE FROM databases WHERE id = $1::uuid", [
      Ecto.UUID.dump!(database_id)
    ])

    Wait.until(fn -> ReadModel.peek(:databases, database_id) == :missing end)
    Wait.until(fn -> ReadModel.peek(:database_tokens, token_hash) == :missing end)
  end

  defp insert_tenant(conn, tenant_id) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO tenants (id, name, slug, inserted_at, updated_at)
      VALUES ($1::uuid, 'Repl Org', $2, now(), now())
      """,
      [Ecto.UUID.dump!(tenant_id), "repl-#{System.unique_integer([:positive])}"]
    )
  end

  defp insert_database(conn, database_id, tenant_id) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO databases (id, tenant_id, name, status, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'repl-db', 'active', now(), now())
      """,
      [Ecto.UUID.dump!(database_id), Ecto.UUID.dump!(tenant_id)]
    )
  end

  defp insert_token(conn, database_id, token, token_hash) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO database_tokens
        (id, database_id, token_hash, token_ciphertext, enabled, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, $2, $3, true, now(), now())
      """,
      [Ecto.UUID.dump!(database_id), token_hash, Smolsqls.Secrets.encrypt(token)]
    )
  end

  defp start_raw_conn! do
    config =
      Application.fetch_env!(:smolsqls, Smolsqls.Repo)
      |> Keyword.take([:hostname, :username, :password, :database, :port])

    {:ok, conn} = Postgrex.start_link(config)
    conn
  end
end
