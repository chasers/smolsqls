defmodule Sqlites.Secrets do
  @moduledoc """
  At-rest handling for credential secrets (decided 2026-07-04): the
  database stores a SHA-256 hash (hex, the auth lookup key) plus an
  AES-256-GCM ciphertext (revealed only on explicit request) — never
  the plaintext. Tokens are 256-bit random values, so an unsalted,
  fast hash is the correct construction (nothing to dictionary-attack)
  and keeps the per-request auth path cheap.

  The encryption key comes from `config :sqlites, Sqlites.Secrets,
  key:` (32 bytes); production derives it from `TOKEN_ENCRYPTION_KEY`
  or, absent that, from `SECRET_KEY_BASE`. Rotating the key breaks
  reveal for existing secrets but never breaks authentication — the
  hash does not involve the key.
  """

  @aad "sqlites-secrets"

  @spec hash(String.t()) :: String.t()
  def hash(secret) when is_binary(secret) do
    Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
  end

  @spec encrypt(String.t()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary()) :: {:ok, String.t()} | :error
  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_blob), do: :error

  defp key do
    Application.fetch_env!(:sqlites, __MODULE__)
    |> Keyword.fetch!(:key)
    |> normalize_key()
  end

  defp normalize_key(key) when byte_size(key) == 32, do: key
  defp normalize_key(key) when is_binary(key), do: :crypto.hash(:sha256, key)
end
