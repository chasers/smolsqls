defmodule Sqlites.DataPlane.SqlTest do
  use ExUnit.Case, async: true

  alias Sqlites.DataPlane.Sql

  describe "write?/1" do
    test "classifies reads as read-only" do
      refute Sql.write?("SELECT * FROM t")
      refute Sql.write?("  select 1")
      refute Sql.write?("EXPLAIN QUERY PLAN DELETE FROM t")
      refute Sql.write?("VALUES (1), (2)")
      refute Sql.write?("PRAGMA table_info(t)")
      refute Sql.write?("-- comment\nSELECT 1")
      refute Sql.write?("/* comment */ SELECT 1")
    end

    test "classifies mutations as writes" do
      assert Sql.write?("INSERT INTO t VALUES (1)")
      assert Sql.write?("UPDATE t SET v = 1")
      assert Sql.write?("DELETE FROM t")
      assert Sql.write?("CREATE TABLE t (v TEXT)")
      assert Sql.write?("DROP TABLE t")
      assert Sql.write?("ALTER TABLE t ADD COLUMN w TEXT")
      assert Sql.write?("REPLACE INTO t VALUES (1)")
      assert Sql.write?("ANALYZE")
      assert Sql.write?("PRAGMA journal_mode=DELETE")
      assert Sql.write?("PRAGMA optimize")
    end

    test "treats anything ambiguous as a write" do
      assert Sql.write?("WITH x AS (SELECT 1) SELECT * FROM x")
      assert Sql.write?("")
    end
  end

  describe "transaction_control?/1" do
    test "detects transaction statements" do
      assert Sql.transaction_control?("BEGIN")
      assert Sql.transaction_control?("begin transaction")
      assert Sql.transaction_control?("COMMIT")
      assert Sql.transaction_control?("END TRANSACTION")
      assert Sql.transaction_control?("ROLLBACK")
      assert Sql.transaction_control?("SAVEPOINT sp1")
      assert Sql.transaction_control?("RELEASE sp1")
      assert Sql.transaction_control?("BEGIN;")
    end

    test "does not flag ordinary statements" do
      refute Sql.transaction_control?("SELECT 1")
      refute Sql.transaction_control?("INSERT INTO t VALUES (1)")
    end
  end
end
