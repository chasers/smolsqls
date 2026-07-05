defmodule Sqlites.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Sqlites.RateLimiter

  test "nil limit always allows" do
    assert RateLimiter.allow?("db-nil-#{System.unique_integer()}", nil)
  end

  test "allows up to the limit within a window, then rejects" do
    database_id = "db-#{System.unique_integer([:positive])}"

    results = for _ <- 1..5, do: RateLimiter.allow?(database_id, 3)

    assert Enum.count(results, & &1) == 3
    assert Enum.take(results, 3) == [true, true, true]
    refute RateLimiter.allow?(database_id, 3)
  end

  test "limits are per database" do
    a = "db-a-#{System.unique_integer([:positive])}"
    b = "db-b-#{System.unique_integer([:positive])}"

    refute Enum.all?(for _ <- 1..5, do: RateLimiter.allow?(a, 1))
    assert RateLimiter.allow?(b, 1)
  end
end
