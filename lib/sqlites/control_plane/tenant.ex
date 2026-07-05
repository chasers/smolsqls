defmodule Sqlites.ControlPlane.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :api_key, :string, virtual: true, redact: true
    field :limits, :map, default: %{}

    has_many :databases, Sqlites.ControlPlane.Database
    has_many :api_keys, Sqlites.ControlPlane.TenantApiKey

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/)
    |> unique_constraint(:slug)
  end

  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
