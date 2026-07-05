defmodule Sqlites.ReadModel.ReplicationTest do
  @moduledoc """
  Drives the real WAL feed: writes are committed through a raw Postgrex
  connection (outside the sandbox), streamed through the logical
  replication slot, decoded from pgoutput, and asserted in ETS.
  Skipped when the Postgres server does not have `wal_level=logical`.
  """

  use ExUnit.Case, async: false

  alias Sqlites.ReadModel

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
        [Sqlites.ReadModel.Replication.slot_name()]
      )

      GenServer.stop(cleanup)
    end)

    start_supervised!({ReadModel, snapshot: false})
    start_supervised!(Sqlites.ReadModel.Replication)

    %{conn: conn, tenant_id: tenant_id, database_id: database_id}
  end

  test "insert, update, and delete flow from the WAL into ETS",
       %{conn: conn, tenant_id: tenant_id, database_id: database_id} do
    api_key = "sk_repl_#{System.unique_integer([:positive])}"
    token = "tok_repl_#{System.unique_integer([:positive])}"

    Postgrex.query!(
      conn,
      """
      INSERT INTO tenants (id, name, slug, inserted_at, updated_at)
      VALUES ($1::uuid, 'Repl Org', $2, now(), now())
      """,
      [Ecto.UUID.dump!(tenant_id), "repl-#{System.unique_integer([:positive])}"]
    )

    Postgrex.query!(
      conn,
      """
      INSERT INTO tenant_api_keys
        (id, tenant_id, token_hash, token_ciphertext, enabled, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, $2, $3, true, now(), now())
      """,
      [
        Ecto.UUID.dump!(tenant_id),
        Sqlites.Secrets.hash(api_key),
        Sqlites.Secrets.encrypt(api_key)
      ]
    )

    wait_until(fn ->
      ReadModel.get_tenant_api_key_by_hash(Sqlites.Secrets.hash(api_key)) != nil
    end)

    assert ReadModel.get_tenant(tenant_id).name == "Repl Org"

    Postgrex.query!(
      conn,
      """
      INSERT INTO databases (id, tenant_id, name, status, inserted_at, updated_at)
      VALUES ($1::uuid, $2::uuid, 'repl-db', 'active', now(), now())
      """,
      [Ecto.UUID.dump!(database_id), Ecto.UUID.dump!(tenant_id)]
    )

    token_hash = Sqlites.Secrets.hash(token)

    Postgrex.query!(
      conn,
      """
      INSERT INTO database_tokens
        (id, database_id, token_hash, token_ciphertext, enabled, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1::uuid, $2, $3, true, now(), now())
      """,
      [Ecto.UUID.dump!(database_id), token_hash, Sqlites.Secrets.encrypt(token)]
    )

    wait_until(fn -> ReadModel.get_database(database_id) != nil end)
    wait_until(fn -> ReadModel.get_database_token_by_hash(token_hash) != nil end)

    found = ReadModel.get_database_token_by_hash(token_hash)
    assert found.database_id == database_id
    assert found.enabled

    Postgrex.query!(
      conn,
      "UPDATE databases SET node = 'claimed@somewhere', updated_at = now() WHERE id = $1::uuid",
      [Ecto.UUID.dump!(database_id)]
    )

    wait_until(fn ->
      match?(%{node: "claimed@somewhere"}, ReadModel.get_database(database_id))
    end)

    Postgrex.query!(
      conn,
      "UPDATE database_tokens SET enabled = false, updated_at = now() WHERE token_hash = $1",
      [token_hash]
    )

    wait_until(fn ->
      match?(%{enabled: false}, ReadModel.get_database_token_by_hash(token_hash))
    end)

    Postgrex.query!(conn, "DELETE FROM databases WHERE id = $1::uuid", [
      Ecto.UUID.dump!(database_id)
    ])

    wait_until(fn -> ReadModel.get_database(database_id) == nil end)
    wait_until(fn -> ReadModel.get_database_token_by_hash(token_hash) == nil end)
  end

  defp start_raw_conn! do
    config =
      Application.fetch_env!(:sqlites, Sqlites.Repo)
      |> Keyword.take([:hostname, :username, :password, :database, :port])

    {:ok, conn} = Postgrex.start_link(config)
    conn
  end

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
