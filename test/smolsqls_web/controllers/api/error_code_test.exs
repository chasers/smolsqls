defmodule SmolsqlsWeb.Api.ErrorCodeTest do
  use ExUnit.Case, async: true

  alias SmolsqlsWeb.Api.ErrorCode

  describe "classify/1" do
    test "keeps known client errors as their stable codes" do
      assert {:not_found, "not_found", _} = ErrorCode.classify(:not_found)
      assert {:unauthorized, "unauthorized", _} = ErrorCode.classify(:unauthorized)
      assert {:conflict, "no_snapshot", _} = ErrorCode.classify(:no_snapshot)
    end

    test "object-store errors classify per operation" do
      assert {:bad_gateway, "object_storage_put", _} =
               ErrorCode.classify({:object_store, :put, {:s3_status, 411, "<html>...</html>"}})

      assert {:bad_gateway, "object_storage_copy", _} =
               ErrorCode.classify({:object_store, :copy, :not_found})

      assert {:bad_gateway, "object_storage_fetch", _} =
               ErrorCode.classify({:object_store, :fetch, :timeout})
    end

    test "untagged object-store and replication failures classify to their subsystem" do
      assert {:bad_gateway, "object_storage_error", _} =
               ErrorCode.classify({:s3_status, 500, "boom"})

      assert {:bad_gateway, "replication_error", _} = ErrorCode.classify({:litestream, 1})
    end

    test "cluster/RPC failures classify as node_unavailable" do
      assert {:service_unavailable, "node_unavailable", _} =
               ErrorCode.classify({:badrpc, :nodedown})

      assert {:service_unavailable, "node_unavailable", _} =
               ErrorCode.classify({:badtcp, :closed})

      assert {:service_unavailable, "node_unavailable", _} = ErrorCode.classify(:no_survivors)
    end

    test "missing artifacts classify as backup_not_found" do
      assert {:not_found, "backup_not_found", _} = ErrorCode.classify(:backup_not_found)
      assert {:not_found, "backup_not_found", _} = ErrorCode.classify(:no_backups)
      assert {:not_found, "backup_not_found", _} = ErrorCode.classify(:no_idle_snapshot)
    end

    test "binary reasons pass through as query_error (SQL text is client-facing)" do
      assert {:bad_request, "query_error", "no such table: t"} =
               ErrorCode.classify("no such table: t")
    end

    test "unknown terms collapse to a generic internal_error that does not echo the term" do
      leaky = {:some_new_failure, %{secret: "s3cr3t", body: "<html>internal</html>"}}
      assert {:internal_server_error, "internal_error", message} = ErrorCode.classify(leaky)

      refute message =~ "s3cr3t"
      refute message =~ "html"
      refute message =~ "some_new_failure"
    end
  end

  describe "loggable?/1" do
    test "5xx classes are loggable, client 4xx are not" do
      assert ErrorCode.loggable?(:internal_server_error)
      assert ErrorCode.loggable?(:bad_gateway)
      assert ErrorCode.loggable?(:service_unavailable)
      refute ErrorCode.loggable?(:not_found)
      refute ErrorCode.loggable?(:conflict)
    end
  end
end
