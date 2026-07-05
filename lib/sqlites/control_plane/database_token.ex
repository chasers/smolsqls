defmodule Sqlites.ControlPlane.DatabaseToken do
  @moduledoc """
  A permanent auth token for one database. Databases can hold any
  number of tokens; each can be disabled, given an expiration, or
  deleted independently — there is no rotation dance, just token
  management. A database with no usable tokens is unreachable through
  the data plane until a new token is created.

  The secret is stored hashed (auth lookup) plus encrypted (explicit
  reveal), never plaintext — see `Sqlites.Secrets`. The virtual
  `token` field carries the plaintext only on create and reveal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "database_tokens" do
    field :token, :string, virtual: true, redact: true
    field :token_hash, :string, redact: true
    field :token_ciphertext, :binary, redact: true
    field :name, :string
    field :enabled, :boolean, default: true
    field :expires_at, :utc_datetime_usec

    belongs_to :database, Sqlites.ControlPlane.Database

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(token, attrs) do
    secret = generate()

    token
    |> cast(attrs, [:name, :expires_at])
    |> put_change(:token, secret)
    |> put_change(:token_hash, Sqlites.Secrets.hash(secret))
    |> put_change(:token_ciphertext, Sqlites.Secrets.encrypt(secret))
    |> validate_expires_in_future()
  end

  def update_changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :enabled])
    |> validate_required([:enabled])
  end

  def generate do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
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
