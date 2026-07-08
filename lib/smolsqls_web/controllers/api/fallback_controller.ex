defmodule SmolsqlsWeb.Api.FallbackController do
  use Phoenix.Controller, formats: [:json]

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

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "resource not found"}})
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "unauthorized", message: "missing or invalid credentials"}})
  end

  def call(conn, {:error, :database_not_running}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "database_not_running",
        message: "database is not currently placed on any node"
      }
    })
  end

  def call(conn, {:error, :database_limit_reached}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "database_limit_reached",
        message: "tenant has reached its database limit"
      }
    })
  end

  def call(conn, {:error, :last_api_key}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "last_api_key",
        message: "cannot disable or delete the tenant's last usable API key"
      }
    })
  end

  def call(conn, {:error, :rate_limited}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: %{code: "rate_limited", message: "database rate limit exceeded"}})
  end

  def call(conn, {:error, :signup_rate_limited}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: %{
        code: "signup_rate_limited",
        message: "too many accounts created from this IP; try again later"
      }
    })
  end

  def call(conn, {:error, :no_snapshot}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "no_snapshot",
        message: "source database has no snapshot to branch from; create a backup first"
      }
    })
  end

  def call(conn, {:error, :has_branches}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "has_branches",
        message: "database has branches; delete them before deleting this database"
      }
    })
  end

  def call(conn, {:error, :database_busy_in_transaction}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "database_busy_in_transaction",
        message: "database is locked by another connection's open transaction; retry shortly"
      }
    })
  end

  def call(conn, {:error, :query_timeout}) do
    conn
    |> put_status(:request_timeout)
    |> json(%{error: %{code: "query_timeout", message: "query timed out"}})
  end

  def call(conn, {:error, :transactions_not_supported}) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "transactions_not_supported",
        message:
          "interactive transactions (BEGIN/COMMIT/ROLLBACK/SAVEPOINT) are not supported; " <>
            "statements run in autocommit mode"
      }
    })
  end

  def call(conn, {:error, :invalid_cursor}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_cursor", message: "\"after\" does not reference a row"}})
  end

  def call(conn, {:error, :invalid_limit}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_limit", message: "\"limit\" must be a positive integer"}})
  end

  def call(conn, {:error, :missing_sql}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_sql", message: "request body requires a \"sql\" field"}})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "query_error", message: reason}})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: %{code: "internal_error", message: inspect(reason)}})
  end
end
