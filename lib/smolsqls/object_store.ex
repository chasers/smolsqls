defmodule Smolsqls.ObjectStore do
  @moduledoc """
  Port for the backup artifact store. Production uses S3-compatible
  storage; dev/test use the local filesystem. Calls execute on whatever
  node invokes them — backup/restore run on the database's owning node,
  so artifact locality follows file locality.
  """

  @callback put_file(key :: String.t(), source_path :: Path.t()) ::
              {:ok, size_bytes :: non_neg_integer()} | {:error, term()}
  @callback fetch_to_file(key :: String.t(), dest_path :: Path.t()) :: :ok | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}
  @callback copy(source_key :: String.t(), dest_key :: String.t()) ::
              {:ok, size_bytes :: non_neg_integer()} | {:error, term()}

  def put_file(key, source_path), do: adapter().put_file(key, source_path)
  def fetch_to_file(key, dest_path), do: adapter().fetch_to_file(key, dest_path)
  def delete(key), do: adapter().delete(key)

  @doc """
  Server-side copy of an existing object to a new key, returning the
  copied object's size. Used to promote an idle snapshot into an
  immutable backup without downloading and re-uploading it.
  """
  def copy(source_key, dest_key), do: adapter().copy(source_key, dest_key)

  defp adapter do
    Application.fetch_env!(:smolsqls, __MODULE__)[:adapter]
  end
end
