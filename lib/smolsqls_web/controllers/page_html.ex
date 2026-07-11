defmodule SmolsqlsWeb.PageHTML do
  @moduledoc """
  Templates for the public home page, rendered by `SmolsqlsWeb.HomeLive`.

  See the `page_html` directory for all templates available.
  """
  use SmolsqlsWeb, :html

  embed_templates "page_html/*"
end
