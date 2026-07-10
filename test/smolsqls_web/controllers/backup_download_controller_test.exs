defmodule SmolsqlsWeb.BackupDownloadControllerTest do
  use SmolsqlsWeb.ConnCase

  import Smolsqls.Fixtures

  alias Smolsqls.DataPlane

  defp backup(tenant) do
    database = placed_database_fixture(tenant)
    {:ok, _} = DataPlane.query(database.id, "CREATE TABLE t (v TEXT)")
    on_exit(fn -> Smolsqls.Backups.delete_all(database) end)
    {:ok, backup} = Smolsqls.Backups.trigger(database)
    {database, backup}
  end

  test "downloads the backup file for the session's tenant", %{conn: conn} do
    tenant = tenant_fixture()
    {database, backup} = backup(tenant)

    resp =
      conn
      |> init_test_session(%{api_key: tenant.api_key})
      |> get(~p"/dashboard/databases/#{database.id}/backups/#{backup.id}/download")

    assert String.starts_with?(response(resp, 200), "SQLite format 3")
    assert ["application/vnd.sqlite3"] = get_resp_header(resp, "content-type")
  end

  test "404s without a session", %{conn: conn} do
    tenant = tenant_fixture()
    {database, backup} = backup(tenant)

    conn
    |> get(~p"/dashboard/databases/#{database.id}/backups/#{backup.id}/download")
    |> response(404)
  end

  test "404s across tenants", %{conn: conn} do
    owner = tenant_fixture()
    {database, backup} = backup(owner)
    other = tenant_fixture()

    conn
    |> init_test_session(%{api_key: other.api_key})
    |> get(~p"/dashboard/databases/#{database.id}/backups/#{backup.id}/download")
    |> response(404)
  end
end
