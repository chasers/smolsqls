defmodule Smolsqls.ObjectStore.Local do
  @moduledoc """
  Filesystem-backed object store for dev/test. Objects live under
  `<data_dir>/object_store/<key>`.
  """

  @behaviour Smolsqls.ObjectStore

  @impl true
  def put_file(key, source_path) do
    dest = object_path(key)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source_path, dest)
    %File.Stat{size: size} = File.stat!(dest)
    {:ok, size}
  end

  @impl true
  def fetch_to_file(key, dest_path) do
    source = object_path(key)

    if File.exists?(source) do
      File.mkdir_p!(Path.dirname(dest_path))
      File.cp!(source, dest_path)
      :ok
    else
      {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    File.rm(object_path(key))
    :ok
  end

  @impl true
  def copy(source_key, dest_key) do
    source = object_path(source_key)

    if File.exists?(source) do
      dest = object_path(dest_key)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
      %File.Stat{size: size} = File.stat!(dest)
      {:ok, size}
    else
      {:error, :not_found}
    end
  end

  defp object_path(key) do
    Application.fetch_env!(:smolsqls, :data_dir)
    |> Path.join("object_store")
    |> Path.join(key)
  end
end
