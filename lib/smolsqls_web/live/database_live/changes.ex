defmodule SmolsqlsWeb.DatabaseLive.Changes do
  use SmolsqlsWeb, :live_view

  alias Smolsqls.ControlPlane
  alias Smolsqls.DataPlane.ChangeStream

  @max_rendered_events 200

  @impl true
  def mount(%{"database_id" => database_id}, session, socket) do
    with {:ok, tenant} <- authenticate(session),
         %{} = database <- ControlPlane.get_database(tenant, database_id) do
      if connected?(socket), do: ChangeStream.subscribe(database.id)

      {:ok,
       socket
       |> assign(:tenant, tenant)
       |> assign(:database, database)
       |> assign(:page_title, "Changes · #{database.name}")
       |> assign(:event_count, 0)
       |> stream(:events, [])}
    else
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Database not found")
         |> redirect(to: ~p"/dashboard")}

      {:error, :unauthorized} ->
        {:ok, redirect(socket, to: ~p"/")}

      {:error, :metadb_unavailable} ->
        {:ok,
         socket
         |> put_flash(:error, "The dashboard is temporarily unavailable — try again shortly")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("ping", _params, socket), do: {:reply, %{}, socket}

  @impl true
  def handle_info({:smolsqls_change, _database_id, event}, socket) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      received_at: DateTime.utc_now(),
      action: event.action,
      table: event.table,
      rowid: event.rowid,
      record: event.record
    }

    {:noreply,
     socket
     |> assign(:event_count, socket.assigns.event_count + 1)
     |> stream_insert(:events, entry, at: 0, limit: @max_rendered_events)}
  end

  defp authenticate(session) do
    case session["api_key"] do
      nil -> {:error, :unauthorized}
      api_key -> ControlPlane.authenticate_tenant(api_key)
    end
  end

  defp record_json(nil), do: "—"
  defp record_json(record), do: Jason.encode!(record)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} logged_in?={true}>
      <div class="mx-auto max-w-4xl space-y-6 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight">
              <span class="font-mono">{@database.name}</span> — change stream
            </h1>
            <p class="text-sm text-base-content/60">
              Live inserts, updates, and deletes as they land. {@event_count} event(s) this session.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <span class="badge badge-sm badge-soft badge-success">live</span>
            <.link navigate={~p"/dashboard"} class="btn btn-ghost btn-sm">Back to databases</.link>
          </div>
        </div>

        <div class="card border border-base-300 bg-base-200">
          <div class="card-body">
            <p :if={@event_count == 0} class="text-center text-base-content/50 py-8">
              Waiting for changes — write to this database and events appear here.
            </p>
            <table :if={@event_count > 0} class="table table-sm">
              <thead>
                <tr>
                  <th>received</th>
                  <th>action</th>
                  <th>table</th>
                  <th>rowid</th>
                  <th>record</th>
                </tr>
              </thead>
              <tbody id="change-events" phx-update="stream">
                <tr :for={{dom_id, event} <- @streams.events} id={dom_id}>
                  <td class="whitespace-nowrap font-mono text-xs">
                    {Calendar.strftime(event.received_at, "%H:%M:%S UTC")}
                  </td>
                  <td>
                    <span class={[
                      "badge badge-xs badge-soft",
                      event.action == :insert && "badge-success",
                      event.action == :update && "badge-info",
                      event.action == :delete && "badge-error"
                    ]}>
                      {event.action}
                    </span>
                  </td>
                  <td class="font-mono text-xs">{event.table}</td>
                  <td class="font-mono text-xs">{event.rowid}</td>
                  <td class="font-mono text-xs break-all">{record_json(event.record)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
