defmodule SqlitesWeb.DatabaseLive.Index do
  use SqlitesWeb, :live_view

  alias Sqlites.ControlPlane

  @impl true
  def mount(_params, session, socket) do
    case authenticate(session) do
      {:ok, tenant} ->
        {:ok,
         socket
         |> assign(:tenant, tenant)
         |> assign(:page_title, "Databases")
         |> assign(:new_database_form, to_form(%{"name" => ""}))
         |> assign(:revealed_database_id, nil)
         |> assign(:reveal_token, nil)
         |> assign(:backups, [])
         |> load_databases()}

      {:error, :unauthorized} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create", %{"name" => name}, socket) do
    case Sqlites.create_database(socket.assigns.tenant, %{"name" => name}) do
      {:ok, database} ->
        {:noreply,
         socket
         |> put_flash(:info, "Database #{database.name} created")
         |> assign(:new_database_form, to_form(%{"name" => ""}))
         |> load_databases()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid name: #{inspect(changeset.errors[:name])}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with database when not is_nil(database) <-
           ControlPlane.get_database(socket.assigns.tenant, id),
         {:ok, _} <- Sqlites.remove_database(database) do
      {:noreply,
       socket
       |> put_flash(:info, "Database deleted")
       |> load_databases()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Delete failed")}
    end
  end

  def handle_event("backup", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant

    with database when not is_nil(database) <- ControlPlane.get_database(tenant, id),
         {:ok, backup} <- Sqlites.Backups.trigger(database) do
      {:noreply,
       socket
       |> put_flash(:info, "Backup #{backup.id} created")
       |> load_backups(database)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Backup failed")}
    end
  end

  def handle_event("restore", %{"id" => id, "backup-id" => backup_id}, socket) do
    tenant = socket.assigns.tenant

    with database when not is_nil(database) <- ControlPlane.get_database(tenant, id),
         :ok <- Sqlites.Backups.restore(database, backup_id) do
      {:noreply, put_flash(socket, :info, "Restored from backup #{backup_id}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Restore failed")}
    end
  end

  def handle_event("toggle_connection", %{"id" => id}, socket) do
    if socket.assigns.revealed_database_id == id do
      {:noreply, assign(socket, revealed_database_id: nil, reveal_token: nil, backups: [])}
    else
      database = ControlPlane.get_database(socket.assigns.tenant, id)

      {:noreply,
       socket
       |> assign(:revealed_database_id, id)
       |> assign(:reveal_token, usable_token(database))
       |> load_backups(database)}
    end
  end

  defp usable_token(nil), do: nil

  defp usable_token(database) do
    with %ControlPlane.DatabaseToken{} = token <-
           database
           |> ControlPlane.list_database_tokens()
           |> Enum.find(&ControlPlane.token_usable?/1),
         {:ok, revealed} <- ControlPlane.reveal(token) do
      revealed
    else
      _ -> nil
    end
  end

  defp load_backups(socket, nil), do: assign(socket, :backups, [])

  defp load_backups(socket, database) do
    if socket.assigns.revealed_database_id == database.id do
      assign(socket, :backups, Sqlites.Backups.list(database))
    else
      socket
    end
  end

  defp load_databases(socket) do
    assign(socket, :databases, ControlPlane.list_databases(socket.assigns.tenant))
  end

  defp authenticate(session) do
    case session["api_key"] do
      nil -> {:error, :unauthorized}
      api_key -> ControlPlane.authenticate_tenant(api_key)
    end
  end

  defp connection_string(database, token) do
    host = SqlitesWeb.Endpoint.host()
    port = SqlitesWeb.Endpoint.url() |> URI.parse() |> Map.get(:port)
    "libsql://#{host}:#{port}/#{database.id}?authToken=#{token.token}"
  end

  defp query_url(database) do
    SqlitesWeb.Endpoint.url() <> "/v1/databases/#{database.id}/query"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-4xl space-y-8 py-8">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">{@tenant.name}</h1>
            <p class="text-sm text-base-content/60">{length(@databases)} database(s)</p>
          </div>
          <form action={~p"/logout"} method="post">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button class="btn btn-ghost btn-sm">Sign out</button>
          </form>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h2 class="card-title text-base">New database</h2>
            <.form for={@new_database_form} phx-submit="create" class="flex gap-2">
              <input
                type="text"
                name="name"
                value={@new_database_form[:name].value}
                placeholder="database name (lowercase, dashes, underscores)"
                class="input input-bordered flex-1"
                required
              />
              <button class="btn btn-primary">Create</button>
            </.form>
          </div>
        </div>

        <div class="space-y-3">
          <div :for={database <- @databases} class="card bg-base-200">
            <div class="card-body space-y-2">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <span class="font-mono font-semibold">{database.name}</span>
                  <span class={[
                    "badge badge-sm",
                    database.status == :active && "badge-success",
                    database.status == :pending && "badge-warning",
                    database.status == :deleting && "badge-error"
                  ]}>
                    {database.status}
                  </span>
                  <span :if={database.node} class="text-xs text-base-content/50 font-mono">
                    {database.node}
                  </span>
                </div>
                <div class="flex gap-2">
                  <button
                    class="btn btn-ghost btn-sm"
                    phx-click="toggle_connection"
                    phx-value-id={database.id}
                  >
                    Connect
                  </button>
                  <button class="btn btn-ghost btn-sm" phx-click="backup" phx-value-id={database.id}>
                    Backup
                  </button>
                  <button
                    class="btn btn-ghost btn-sm text-error"
                    phx-click="delete"
                    phx-value-id={database.id}
                    data-confirm={"Delete #{database.name}? This destroys the data."}
                  >
                    Delete
                  </button>
                </div>
              </div>
              <div :if={@revealed_database_id == database.id} class="space-y-2 text-sm">
                <div :if={@reveal_token}>
                  <div class="text-xs text-base-content/60 mb-1">libSQL connection string</div>
                  <code class="block bg-base-300 rounded p-2 font-mono break-all">
                    {connection_string(database, @reveal_token)}
                  </code>
                </div>
                <p :if={is_nil(@reveal_token)} class="text-xs text-warning">
                  No usable tokens — create one via POST /v1/databases/{database.id}/tokens.
                </p>
                <div>
                  <div class="text-xs text-base-content/60 mb-1">
                    HTTP — POST with Authorization: Bearer &lt;auth_token&gt;
                  </div>
                  <code class="block bg-base-300 rounded p-2 font-mono break-all">
                    {query_url(database)}
                  </code>
                </div>
                <div>
                  <div class="text-xs text-base-content/60 mb-1">Backups</div>
                  <p :if={@backups == []} class="text-xs text-base-content/50">
                    No backups yet.
                  </p>
                  <ul class="space-y-1">
                    <li :for={backup <- @backups} class="flex items-center justify-between gap-2">
                      <span class="font-mono text-xs">
                        {Calendar.strftime(backup.inserted_at, "%Y-%m-%d %H:%M:%S UTC")} · {backup.size_bytes} bytes
                      </span>
                      <button
                        class="btn btn-ghost btn-xs"
                        phx-click="restore"
                        phx-value-id={database.id}
                        phx-value-backup-id={backup.id}
                        data-confirm="Restore this backup? Current data will be replaced."
                      >
                        Restore
                      </button>
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>
          <p :if={@databases == []} class="text-center text-base-content/50 py-8">
            No databases yet — create one above.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
