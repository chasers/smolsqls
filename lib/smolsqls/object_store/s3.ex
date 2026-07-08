defmodule Smolsqls.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store via `req_s3` (AWS S3, MinIO, R2, ...).
  Configured under `config :smolsqls, Smolsqls.ObjectStore` with
  `:bucket`, `:access_key_id`, `:secret_access_key`, and optional
  `:endpoint` for non-AWS deployments.

  Objects are stored **gzip-compressed**, transparently: `put_file/2`
  compresses the source and `fetch_to_file/2` decompresses on the way
  back, so callers only ever see the logical (uncompressed) file. Both
  directions stream through `:zlib` to bound memory regardless of database
  size. Reads detect the gzip magic bytes, so objects written before
  compression was introduced still restore. The uncompressed byte count
  travels as `x-amz-meta-logical-length` so `put_file/2` and the
  server-side `copy/2` (backup promotion) report the same logical size.
  """

  @behaviour Smolsqls.ObjectStore

  @chunk_bytes 1_048_576
  @logical_length_header "x-amz-meta-logical-length"

  @impl true
  def put_file(key, source_path) do
    %File.Stat{size: logical_size} = File.stat!(source_path)
    compressed = source_path <> ".gz"

    try do
      gzip_file(source_path, compressed)
      %File.Stat{size: upload_size} = File.stat!(compressed)

      case Req.put(request(),
             url: "s3://#{bucket()}/#{key}",
             headers: [
               {"content-length", Integer.to_string(upload_size)},
               {@logical_length_header, Integer.to_string(logical_size)}
             ],
             body: File.stream!(compressed, @chunk_bytes)
           ) do
        {:ok, %{status: status}} when status in 200..299 -> {:ok, logical_size}
        {:ok, %{status: status, body: body}} -> {:error, {:s3_status, status, body}}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(compressed)
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
        materialize(partial, dest_path)
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
        {:ok, logical_length(response)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:s3_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp logical_length(response) do
    case Req.Response.get_header(response, @logical_length_header) do
      [length | _] -> String.to_integer(length)
      [] -> content_length(response)
    end
  end

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [length | _] -> String.to_integer(length)
      [] -> 0
    end
  end

  defp materialize(partial, dest_path) do
    if gzip?(partial) do
      gunzip_file(partial, dest_path)
      File.rm(partial)
    else
      File.rename!(partial, dest_path)
    end
  end

  defp gzip?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, <<0x1F, 0x8B>>} -> true
      _ -> false
    end
  end

  defp gzip_file(source_path, dest_path) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
    out = File.open!(dest_path, [:write, :binary])

    try do
      source_path
      |> File.stream!(@chunk_bytes)
      |> Enum.each(fn chunk -> IO.binwrite(out, :zlib.deflate(z, chunk)) end)

      IO.binwrite(out, :zlib.deflate(z, "", :finish))
    after
      File.close(out)
      :zlib.deflateEnd(z)
      :zlib.close(z)
    end

    :ok
  end

  defp gunzip_file(source_path, dest_path) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 31)
    out = File.open!(dest_path, [:write, :binary])

    try do
      source_path
      |> File.stream!(@chunk_bytes)
      |> Enum.each(fn chunk -> drain_inflate(z, :zlib.safeInflate(z, chunk), out) end)
    after
      File.close(out)
      :zlib.inflateEnd(z)
      :zlib.close(z)
    end

    :ok
  end

  defp drain_inflate(z, {:continue, output}, out) do
    IO.binwrite(out, output)
    drain_inflate(z, :zlib.safeInflate(z, <<>>), out)
  end

  defp drain_inflate(_z, {:finished, output}, out) do
    IO.binwrite(out, output)
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
