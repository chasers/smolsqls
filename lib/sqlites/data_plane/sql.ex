defmodule Sqlites.DataPlane.Sql do
  @moduledoc """
  Heuristic statement classification. `transaction_control?/1` detects
  statements that would leak transaction state across the shared
  connection (rejected at every protocol edge). `write?/1` is advisory
  only — it backs Hrana `describe`'s `is_readonly` field and errs
  toward `true`; it deliberately does NOT drive idle-snapshot dirty
  tracking (every session ships until a proper SQL parser can be
  trusted with that decision).
  """

  @transaction_keywords ~w(begin commit end rollback savepoint release)

  @spec write?(String.t()) :: boolean()
  def write?(sql) when is_binary(sql) do
    case first_keyword(sql) do
      "select" -> false
      "explain" -> false
      "values" -> false
      "pragma" -> pragma_write?(sql)
      _ -> true
    end
  end

  @spec transaction_control?(String.t()) :: boolean()
  def transaction_control?(sql) when is_binary(sql) do
    first_keyword(sql) in @transaction_keywords
  end

  defp pragma_write?(sql) do
    body = sql |> skip_leading_trivia() |> String.downcase()

    String.contains?(body, "=") or
      String.starts_with?(body, "pragma optimize") or
      String.starts_with?(body, "pragma incremental_vacuum")
  end

  defp first_keyword(sql) do
    sql
    |> skip_leading_trivia()
    |> String.split(~r/[\s;(]/, parts: 2)
    |> hd()
    |> String.downcase()
  end

  defp skip_leading_trivia(sql) do
    trimmed = String.trim_leading(sql)

    cond do
      String.starts_with?(trimmed, "--") ->
        trimmed
        |> String.split("\n", parts: 2)
        |> case do
          [_comment, rest] -> skip_leading_trivia(rest)
          [_comment] -> ""
        end

      String.starts_with?(trimmed, "/*") ->
        trimmed
        |> String.split("*/", parts: 2)
        |> case do
          [_comment, rest] -> skip_leading_trivia(rest)
          [_comment] -> ""
        end

      true ->
        trimmed
    end
  end
end
