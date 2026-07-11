defmodule SmolsqlsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SmolsqlsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @github_url "https://github.com/chasers/smolsqls"

  @doc "URL of the project's GitHub repository."
  def github_url, do: @github_url

  @doc "The running application's version, e.g. \"0.1.0\"."
  def app_version, do: :smolsqls |> Application.spec(:vsn) |> to_string()

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 border-b border-base-300 bg-base-100/90 backdrop-blur">
      <div class="mx-auto flex h-12 max-w-5xl items-center justify-between px-4 sm:px-6 lg:px-8">
        <div class="flex items-center gap-2">
          <a href="/" class="flex items-center gap-2">
            <.icon name="hero-bolt-solid" class="size-4 text-accent" />
            <span class="text-sm font-semibold tracking-tight">smolsqls</span>
          </a>
          <a
            href={github_url() <> "/releases"}
            target="_blank"
            rel="noopener noreferrer"
            class="rounded-full border border-base-300 px-1.5 py-0.5 font-mono text-[10px] text-base-content/50 transition-colors hover:text-base-content"
          >
            v{app_version()}
          </a>
        </div>
        <nav class="flex items-center gap-4">
          <a
            href={github_url()}
            target="_blank"
            rel="noopener noreferrer"
            class="text-sm text-base-content/60 transition-colors hover:text-base-content"
          >
            GitHub
          </a>
          <a
            href="/v1"
            class="text-sm text-base-content/60 transition-colors hover:text-base-content"
          >
            API
          </a>
          <div
            id="region-latency"
            phx-hook=".RegionLatency"
            class="flex items-center gap-1.5 rounded-full border border-base-300 px-2 py-0.5 font-mono text-[10px] text-base-content/60"
            title="Region serving this session · round-trip latency"
          >
            <span class="inline-block size-1.5 rounded-full bg-success" aria-hidden="true"></span>
            <span>{Smolsqls.Regions.self_region() || "local"}</span>
            <span class="text-base-content/30">·</span>
            <span data-latency>…</span>
          </div>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />

    <script :type={Phoenix.LiveView.ColocatedHook} name=".RegionLatency">
      export default {
        mounted() {
          const out = this.el.querySelector("[data-latency]")
          const ping = () => {
            const t0 = performance.now()
            this.pushEvent("ping", {}, () => {
              out.textContent = Math.round(performance.now() - t0) + " ms"
            })
          }
          ping()
          this.timer = setInterval(ping, 5000)
        },
        destroyed() { if (this.timer) clearInterval(this.timer) }
      }
    </script>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300 bg-base-200">
      <div class="absolute h-full w-1/3 rounded-full border border-base-300 bg-base-300/60 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-1.5"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-3.5 opacity-60 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
