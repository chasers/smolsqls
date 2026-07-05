defmodule Sqlites.SecretsTest do
  use ExUnit.Case, async: true

  alias Sqlites.Secrets

  test "hash/1 is deterministic hex" do
    assert Secrets.hash("abc") == Secrets.hash("abc")
    assert Secrets.hash("abc") != Secrets.hash("abd")
    assert Secrets.hash("abc") =~ ~r/^[0-9a-f]{64}$/
  end

  test "encrypt/decrypt round-trips with a fresh IV per call" do
    secret = "tok_#{System.unique_integer([:positive])}"

    first = Secrets.encrypt(secret)
    second = Secrets.encrypt(secret)

    assert first != second
    assert {:ok, ^secret} = Secrets.decrypt(first)
    assert {:ok, ^secret} = Secrets.decrypt(second)
  end

  test "decrypt/1 rejects tampered or malformed blobs" do
    blob = Secrets.encrypt("secret")
    <<head::binary-size(20), byte, rest::binary>> = blob

    assert :error = Secrets.decrypt(head <> <<Bitwise.bxor(byte, 1)>> <> rest)
    assert :error = Secrets.decrypt("too-short")
  end
end
