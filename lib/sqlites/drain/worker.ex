defmodule Sqlites.Drain.Worker do
  @moduledoc """
  Polls the `node_drains` table and executes pending drains. The
  operator's drain reconcile only inserts rows here — the data plane
  owns re-placement. Claims use `FOR UPDATE SKIP LOCKED`, so exactly
  one node in the cluster executes each request.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Sqlites.Drain
  alias Sqlites.Drain.Request
  alias Sqlites.Repo

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll()
    schedule_poll()
    {:noreply, state}
  end

  @spec poll() :: :ok
  def poll do
    case claim_next() do
      %Request{} = request -> execute(request)
      nil -> :ok
    end
  end

  defp claim_next do
    {:ok, claimed} =
      Repo.transaction(fn ->
        Request
        |> where([r], is_nil(r.started_at) and is_nil(r.completed_at))
        |> order_by([r], asc: r.requested_at)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()
        |> case do
          nil ->
            nil

          request ->
            request
            |> Ecto.Changeset.change(
              started_at: DateTime.utc_now(),
              started_by: to_string(Node.self())
            )
            |> Repo.update!()
        end
      end)

    claimed
  end

  defp execute(%Request{node: node} = request) do
    case Drain.drain(node) do
      {:ok, %{reassigned: reassigned}} ->
        complete(request, reassigned: reassigned)

      {:error, reason} ->
        Logger.error("drain of #{node} failed: #{inspect(reason)}")
        complete(request, error: String.slice(inspect(reason), 0, 250))
    end

    :ok
  end

  defp complete(%Request{} = request, fields) do
    request
    |> Ecto.Changeset.change(Keyword.put(fields, :completed_at, DateTime.utc_now()))
    |> Repo.update!()
  end

  defp schedule_poll do
    interval = Application.get_env(:sqlites, __MODULE__, [])[:poll_interval] || :timer.seconds(5)
    Process.send_after(self(), :poll, interval)
  end
end
