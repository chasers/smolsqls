defmodule Smolsqls.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store via `req_s3` (AWS S3, MinIO, R2, ...).
  Configured under `config :smolsqls, Smolsqls.ObjectStore` with
  `:bucket`, `:access_key_id`, `:secret_access_key`, and optional
  `:endpoint` for non-AWS deployments.
  """

  @behaviour Smolsqls.ObjectStore

  @impl true
  def put_file(key, source_path) do
    body = File.read!(source_path)

    case Req.put(request(), url: "s3://#{bucket()}/#{key}", body: body) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, byte_size(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_to_file(key, dest_path) do
    case Req.get(request(), url: "s3://#{bucket()}/#{key}", raw: true) do
      {:ok, %{status: 200, body: body}} ->
        File.mkdir_p!(Path.dirname(dest_path))
        File.write!(dest_path, body)
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case Req.delete(request(), url: "s3://#{bucket()}/#{key}") do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:s3_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def copy(source_key, dest_key) do
    case Req.put(request(),
           url: "s3://#{bucket()}/#{dest_key}",
           headers: [{"x-amz-copy-source", "/#{bucket()}/#{source_key}"}]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> object_size(dest_key)
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_size(key) do
    case Req.head(request(), url: "s3://#{bucket()}/#{key}") do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_header(response, "content-length") do
          [length | _] -> {:ok, String.to_integer(length)}
          [] -> {:ok, 0}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request do
    Req.new()
    |> ReqS3.attach(
      aws_sigv4: [
        access_key_id: config()[:access_key_id],
        secret_access_key: config()[:secret_access_key]
      ],
      aws_endpoint_url_s3: config()[:endpoint]
    )
  end

  defp bucket, do: config()[:bucket]

  defp config, do: Application.fetch_env!(:smolsqls, Smolsqls.ObjectStore)
end
