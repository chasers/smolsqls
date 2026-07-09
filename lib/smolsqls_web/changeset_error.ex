defmodule SmolsqlsWeb.ChangesetError do
  @moduledoc """
  Humanizes an `Ecto.Changeset`'s errors into a short, user-facing sentence for
  flash messages — so views surface validation feedback without `inspect`-ing
  the changeset's internal error structure.
  """

  @spec message(Ecto.Changeset.t()) :: String.t()
  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
