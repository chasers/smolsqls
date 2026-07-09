defmodule SmolsqlsWeb.Api.FallbackControllerTest do
  use SmolsqlsWeb.ConnCase, async: true

  alias SmolsqlsWeb.Api.FallbackController

  test "an opaque object-store failure is classified without leaking the raw term", %{conn: conn} do
    leaky =
      {:error,
       {:object_store, :put, {:s3_status, 411, "<html>Error 411 (Length Required)</html>"}}}

    conn = FallbackController.call(conn, leaky)

    assert conn.status == 502
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "object_storage_put"
    assert body["error"]["message"] == "object storage operation failed"
    assert Map.has_key?(body["error"], "request_id")

    refute conn.resp_body =~ "Length Required"
    refute conn.resp_body =~ "html"
    refute conn.resp_body =~ "s3_status"
  end

  test "an unrecognized internal term collapses to internal_error, not inspect", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, {:totally_new, self()}})

    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "internal_error"
    assert body["error"]["message"] == "an internal error occurred"
    refute conn.resp_body =~ "totally_new"
  end

  test "known client errors keep their code and carry no request_id", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, :no_snapshot})

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "no_snapshot"
    refute Map.has_key?(body["error"], "request_id")
  end
end
