defmodule Smolsqls.ControlPlane.Backup do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "backups" do
    field :object_key, :string
    field :size_bytes, :integer
    field :origin, Ecto.Enum, values: [:manual, :automatic], default: :manual

    belongs_to :database, Smolsqls.ControlPlane.Database

    timestamps(type: :utc_datetime_usec)
  end
end
