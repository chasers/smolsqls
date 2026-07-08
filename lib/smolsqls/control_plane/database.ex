defmodule Smolsqls.ControlPlane.Database do
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

    field :source_database_id, :binary_id
    field :branch_point_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :tenant, Smolsqls.ControlPlane.Tenant
    has_many :tokens, Smolsqls.ControlPlane.DatabaseToken

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

  @doc """
  Changeset for a database provisioned as a copy of another (a branch or
  a lineage-less clone). `source_database_id` records the parent when set;
  `branch_point_at` is the moment the copy was taken; `expires_at`, when
  set, marks the database ephemeral (swept once past).
  """
  def branch_changeset(database, attrs) do
    database
    |> cast(attrs, [
      :name,
      :tenant_id,
      :litestream_enabled,
      :source_database_id,
      :branch_point_at,
      :expires_at
    ])
    |> validate_required([:name, :tenant_id])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> unique_constraint([:tenant_id, :name])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:source_database_id)
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
