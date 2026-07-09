defmodule SmolsqlsWeb.Api.FallbackController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias SmolsqlsWeb.Api.ErrorCode

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "validation_failed", details: errors}})
  end

  def call(conn, {:error, reason}) do
    {status, code, message} = ErrorCode.classify(reason)

    conn
    |> put_status(status)
    |> json(%{error: error_body(status, code, message, reason)})
  end

  defp error_body(status, code, message, reason) do
    if ErrorCode.loggable?(status) do
      request_id = Logger.metadata()[:request_id]

      Logger.error(
        "api error code=#{code} request_id=#{request_id} " <>
          "reason=#{inspect(reason, printable_limit: 2048, limit: 50)}"
      )

      %{code: code, message: message, request_id: request_id}
    else
      %{code: code, message: message}
    end
  end
end
