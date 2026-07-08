defmodule Smolsqls.DataPlane.LitestreamTest do
  use ExUnit.Case, async: false

  alias Smolsqls.ControlPlane.Database
  alias Smolsqls.DataPlane.Litestream

  @moduletag :tmp_dir

  defp database(overrides \\ %{}) do
    struct!(
      %Database{
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        name: "db",
        status: :active,
        auth_token: "t"
      },
      overrides
    )
  end

  test "everything no-ops when disabled" do
    refute Litestream.enabled?()
    assert :ok = Litestream.register(database())
    assert :ok = Litestream.stop("/nonexistent/path.db")
    assert {:error, :litestream_disabled} = Litestream.restore(database(), "/tmp/x.db")
  end

  test "replica urls are database-addressed", %{tmp_dir: tmp_dir} do
    with_config(
      [enabled: true, replica_url_prefix: "s3://bucket/litestream", binary: "true"],
      fn ->
        db = database()
        assert Litestream.replica_url(db) == "s3://bucket/litestream/#{db.tenant_id}/#{db.id}"
      end
    )

    _ = tmp_dir
  end

  test "restore invokes the binary and reports missing replicas", %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "fixture.db")
    File.write!(fixture, "fixture-bytes")

    stub = Path.join(tmp_dir, "litestream-stub")

    File.write!(stub, """
    #!/bin/sh
    if [ "$1" = "restore" ]; then cp #{fixture} "$3"; exit 0; fi
    exit 1
    """)

    File.chmod!(stub, 0o755)

    with_config(
      [enabled: true, replica_url_prefix: "s3://bucket/ls", binary: stub],
      fn ->
        dest = Path.join(tmp_dir, "restored/db.db")
        assert :ok = Litestream.restore(database(), dest)
        assert File.read!(dest) == "fixture-bytes"

        assert {:error, {:litestream, 1}} = Litestream.stop("/some/path.db")
      end
    )
  end

  test "restore passes the point-in-time flag when given an instant", %{tmp_dir: tmp_dir} do
    args_file = Path.join(tmp_dir, "args")
    stub = Path.join(tmp_dir, "litestream-stub")

    File.write!(stub, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{args_file}
    exit 0
    """)

    File.chmod!(stub, 0o755)

    read_args = fn -> File.read!(args_file) |> String.split("\n", trim: true) end

    with_config(
      [enabled: true, replica_url_prefix: "s3://bucket/ls", binary: stub],
      fn ->
        dest = Path.join(tmp_dir, "restored/db.db")
        at = ~U[2026-07-01 12:00:00Z]

        assert :ok = Litestream.restore(database(), dest, timestamp: at)
        args = read_args.()
        assert "-timestamp" in args
        assert "2026-07-01T12:00:00Z" in args

        assert :ok = Litestream.restore(database(), dest)
        refute "-timestamp" in read_args.()
      end
    )
  end

  defp with_config(config, fun) do
    previous = Application.get_env(:smolsqls, Litestream)
    Application.put_env(:smolsqls, Litestream, config)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:smolsqls, Litestream)
        value -> Application.put_env(:smolsqls, Litestream, value)
      end
    end
  end
end
