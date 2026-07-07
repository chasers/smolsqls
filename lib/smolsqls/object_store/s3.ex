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
    %File.Stat{size: size} = File.stat!(source_path)

    case Req.put(request(),
           url: "s3://#{bucket()}/#{key}",
           headers: [content_length: size],
           body: File.stream!(source_path, 1_048_576)
         ) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, size}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_to_file(key, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))
    partial = dest_path <> ".partial"

    case Req.get(request(),
           url: "s3://#{bucket()}/#{key}",
           raw: true,
           into: File.stream!(partial)
         ) do
      {:ok, %{status: 200}} ->
        File.rename!(partial, dest_path)
        :ok

      {:ok, %{status: 404}} ->
        File.rm(partial)
        {:error, :not_found}

      {:ok, %{status: status}} ->
        error = File.read!(partial)
        File.rm(partial)
        {:error, {:s3_status, status, error}}

      {:error, reason} ->
        File.rm(partial)
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
