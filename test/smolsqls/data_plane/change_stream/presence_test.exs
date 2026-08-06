defmodule Smolsqls.DataPlane.ChangeStream.PresenceTest do
  use ExUnit.Case, async: false

  alias Smolsqls.DataPlane.ChangeStream.Presence

  defp unique_topic(label) do
    "presence-test-#{label}-#{System.unique_integer([:positive])}"
  end

  test "count is zero for an untracked topic" do
    assert Presence.count(unique_topic("none")) == 0
  end

  test "mirrors joins, leaves, and tracked-process death into per-topic counts" do
    topic_a = unique_topic("a")
    topic_b = unique_topic("b")

    {:ok, _} = Presence.track(self(), topic_a, "self", %{})
    {:ok, _} = Presence.track(self(), topic_b, "self", %{})

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, _} = Presence.track(other, topic_a, "other", %{})

    Smolsqls.Wait.until(fn -> Presence.count(topic_a) == 2 end)
    Smolsqls.Wait.until(fn -> Presence.count(topic_b) == 1 end)

    send(other, :stop)
    Smolsqls.Wait.until(fn -> Presence.count(topic_a) == 1 end)

    :ok = Presence.untrack(self(), topic_a, "self")
    Smolsqls.Wait.until(fn -> Presence.count(topic_a) == 0 end)

    assert Presence.count(topic_b) == 1
  end
end
