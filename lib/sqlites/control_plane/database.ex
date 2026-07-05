defmodule Sqlites.ControlPlane.Database do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "databases" do
    field :name, :string
    field :status, Ecto.Enum, values: [:pending, :active, :deleting, :error], default: :pending
    field :node, :string
    field :file_path, :string
    field :auth_token, :string, virtual: true, redact: true
    field :litestream_enabled, :boolean, default: false
    field :snapshot_generation, :integer, default: 0
    field :last_snapshot_at, :utc_datetime_usec
    field :limits, :map, default: %{}

    belongs_to :tenant, Sqlites.ControlPlane.Tenant
    has_many :tokens, Sqlites.ControlPlane.DatabaseToken

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(database, attrs) do
    database
    |> cast(attrs, [:name, :tenant_id, :litestream_enabled])
    |> validate_required([:name, :tenant_id])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:tenant_id)
  end

  def placement_changeset(database, attrs) do
    database
    |> cast(attrs, [:status, :node, :file_path])
    |> validate_required([:status])
  end

  def settings_changeset(database, attrs) do
    cast(database, attrs, [:litestream_enabled])
  end
end
