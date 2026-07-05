defmodule Sqlites.ControlPlane.TenantApiKey do
  @moduledoc """
  A permanent management API key for one tenant, managed exactly like
  database tokens: create (optionally with an expiration), disable,
  delete. The last usable key of a tenant cannot be disabled or
  deleted — that would be an unrecoverable lockout.

  The secret is stored hashed (auth lookup) plus encrypted (explicit
  reveal), never plaintext — see `Sqlites.Secrets`. The virtual
  `token` field carries the plaintext only on create and reveal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenant_api_keys" do
    field :token, :string, virtual: true, redact: true
    field :token_hash, :string, redact: true
    field :token_ciphertext, :binary, redact: true
    field :name, :string
    field :enabled, :boolean, default: true
    field :expires_at, :utc_datetime_usec

    belongs_to :tenant, Sqlites.ControlPlane.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(api_key, attrs) do
    secret = generate()

    api_key
    |> cast(attrs, [:name, :expires_at])
    |> put_change(:token, secret)
    |> put_change(:token_hash, Sqlites.Secrets.hash(secret))
    |> put_change(:token_ciphertext, Sqlites.Secrets.encrypt(secret))
    |> validate_expires_in_future()
  end

  def update_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :enabled])
    |> validate_required([:enabled])
  end

  def generate do
    "sk_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp validate_expires_in_future(changeset) do
    case get_change(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        if DateTime.after?(expires_at, DateTime.utc_now()) do
          changeset
        else
          add_error(changeset, :expires_at, "must be in the future")
        end
    end
  end
end
