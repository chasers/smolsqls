defmodule SmolsqlsWeb.AccountLive.Index do
  use SmolsqlsWeb, :live_view

  alias Smolsqls.ControlPlane
  alias SmolsqlsWeb.ChangesetError

  @impl true
  def mount(_params, session, socket) do
    case authenticate(session) do
      {:ok, tenant} ->
        {:ok,
         socket
         |> assign(:tenant, tenant)
         |> assign(:page_title, "API keys")
         |> assign(:new_key_form, to_form(%{"name" => ""}))
         |> assign(:revealed_secrets, %{})
         |> load_keys()}

      {:error, :unauthorized} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("create_key", %{"name" => name}, socket) do
    attrs = if name == "", do: %{}, else: %{"name" => name}

    case ControlPlane.create_tenant_api_key(socket.assigns.tenant, attrs) do
      {:ok, key} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key created — copy it now.")
         |> assign(:new_key_form, to_form(%{"name" => ""}))
         |> assign(:revealed_secrets, Map.put(socket.assigns.revealed_secrets, key.id, key.token))
         |> load_keys()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid: #{ChangesetError.message(changeset)}")}
    end
  end

  def handle_event("reveal_key", %{"key-id" => id}, socket) do
    with %{} = key <- ControlPlane.get_tenant_api_key(socket.assigns.tenant, id),
         {:ok, revealed} <- ControlPlane.reveal(key) do
      {:noreply,
       assign(
         socket,
         :revealed_secrets,
         Map.put(socket.assigns.revealed_secrets, key.id, revealed.token)
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, "Reveal failed")}
    end
  end

  def handle_event("toggle_key", %{"key-id" => id}, socket) do
    with %{} = key <- ControlPlane.get_tenant_api_key(socket.assigns.tenant, id),
         {:ok, _} <- ControlPlane.update_tenant_api_key(key, %{"enabled" => not key.enabled}) do
      {:noreply, load_keys(socket)}
    else
      {:error, :last_api_key} ->
        {:noreply,
         put_flash(socket, :error, "Create another key before disabling your only active one.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Update failed")}
    end
  end

  def handle_event("delete_key", %{"key-id" => id}, socket) do
    with %{} = key <- ControlPlane.get_tenant_api_key(socket.assigns.tenant, id),
         {:ok, _} <- ControlPlane.delete_tenant_api_key(key) do
      {:noreply,
       socket
       |> put_flash(:info, "API key deleted")
       |> load_keys()}
    else
      {:error, :last_api_key} ->
        {:noreply,
         put_flash(socket, :error, "Create another key before deleting your only active one.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Delete failed")}
    end
  end

  defp load_keys(socket) do
    assign(socket, :keys, ControlPlane.list_tenant_api_keys(socket.assigns.tenant))
  end

  defp authenticate(session) do
    case session["api_key"] do
      nil -> {:error, :unauthorized}
      api_key -> ControlPlane.authenticate_tenant(api_key)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-4xl space-y-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight">{@tenant.name}</h1>
            <p class="text-sm text-base-content/60">Account API keys</p>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/dashboard"} class="btn btn-ghost btn-sm">Databases</.link>
            <form action={~p"/logout"} method="post">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button class="btn btn-ghost btn-sm">Sign out</button>
            </form>
          </div>
        </div>

        <div class="card border border-base-300 bg-base-200">
          <div class="card-body">
            <h2 class="text-sm font-medium">New API key</h2>
            <p class="text-sm text-base-content/60">
              Account keys authenticate the management API and this dashboard.
              The secret is shown once on creation — reveal or copy it before leaving.
            </p>
            <.form for={@new_key_form} phx-submit="create_key" class="flex gap-2">
              <input
                type="text"
                name="name"
                value={@new_key_form[:name].value}
                placeholder="key name (optional)"
                class="input input-bordered flex-1"
              />
              <button class="btn btn-primary">Create</button>
            </.form>
          </div>
        </div>

        <ul class="space-y-2">
          <li
            :for={key <- @keys}
            class="card border border-base-300 bg-base-200"
          >
            <div class="card-body flex-col gap-3 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div class="min-w-0 flex-1 space-y-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-mono text-sm font-medium">{key.name || "unnamed"}</span>
                  <span class={[
                    "badge badge-xs badge-soft",
                    (key.enabled && "badge-success") || "badge-error"
                  ]}>
                    {if(key.enabled, do: "enabled", else: "disabled")}
                  </span>
                  <span :if={key.expires_at} class="text-xs text-base-content/50">
                    expires {Calendar.strftime(key.expires_at, "%Y-%m-%d %H:%M UTC")}
                  </span>
                </div>
                <div
                  :if={@revealed_secrets[key.id]}
                  class="flex items-center gap-2"
                >
                  <code
                    id={"secret-#{key.id}"}
                    class="block flex-1 rounded-md border border-base-300 bg-base-100 p-2 font-mono text-xs break-all"
                  >
                    {@revealed_secrets[key.id]}
                  </code>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-hook=".Copy"
                    id={"copy-#{key.id}"}
                    data-copy-target={"secret-#{key.id}"}
                  >
                    Copy
                  </button>
                </div>
              </div>
              <div class="flex gap-1 shrink-0">
                <button
                  :if={is_nil(@revealed_secrets[key.id])}
                  class="btn btn-ghost btn-xs"
                  phx-click="reveal_key"
                  phx-value-key-id={key.id}
                >
                  Reveal
                </button>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="toggle_key"
                  phx-value-key-id={key.id}
                >
                  {if(key.enabled, do: "Disable", else: "Enable")}
                </button>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_key"
                  phx-value-key-id={key.id}
                  data-confirm="Delete this API key? Clients using it lose access."
                >
                  Delete
                </button>
              </div>
            </div>
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const target = document.getElementById(this.el.dataset.copyTarget)
              if (!target) return
              navigator.clipboard.writeText(target.textContent.trim()).then(() => {
                const original = this.el.textContent
                this.el.textContent = "Copied"
                setTimeout(() => { this.el.textContent = original }, 1200)
              })
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
