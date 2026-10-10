defmodule IexCode.OwnerAuth.CredentialsTest do
  use ExUnit.Case, async: false

  alias IexCode.OwnerAuth.Credentials

  setup_all do
    username = "synthetic.owner-1@example.test"
    password = "synthetic " <> Base.encode64(:crypto.strong_rand_bytes(24)) <> " "
    salt = :crypto.strong_rand_bytes(16)
    digest = :crypto.pbkdf2_hmac(:sha256, password, salt, 600_000, 32)
    hash = encode_hash(salt, digest)

    %{username: username, password: password, salt: salt, digest: digest, hash: hash}
  end

  test "parses only the canonical fixed-cost encoding without retaining username or hash",
       fixture do
    assert {:ok, credentials} = Credentials.parse(fixture.username, fixture.hash)

    assert credentials == %{
             username_digest: :crypto.hash(:sha256, fixture.username),
             salt: fixture.salt,
             digest: fixture.digest
           }

    assert {:ok, _} = Credentials.parse(String.duplicate("A", 64), fixture.hash)
    assert {:ok, _} = Credentials.parse("a", fixture.hash)
  end

  test "rejects malformed usernames without normalizing them", %{hash: hash} do
    for username <- [
          nil,
          7,
          [:owner],
          %{},
          "",
          " owner",
          "owner ",
          "owner\n",
          "owner/name",
          "owner:name",
          "é",
          <<255>>,
          String.duplicate("a", 65)
        ] do
      assert Credentials.parse(username, hash) == {:error, :invalid_owner_credentials}
    end
  end

  test "rejects wrong cost, algorithm, field sizes, padding and trailing input", fixture do
    salt64 = Base.encode64(fixture.salt)
    digest64 = Base.encode64(fixture.digest)

    for hash <- [
          nil,
          90,
          %{},
          "",
          String.duplicate("x", 100_000),
          String.replace(fixture.hash, "sha256", "sha512"),
          String.replace(fixture.hash, "600000", "060000"),
          String.replace(fixture.hash, "600000", "600001"),
          "pbkdf2_sha256$600000$#{Base.encode64(:crypto.strong_rand_bytes(15))}$#{digest64}",
          "pbkdf2_sha256$600000$#{salt64}$#{Base.encode64(:crypto.strong_rand_bytes(31))}",
          String.replace(fixture.hash, "=", ""),
          fixture.hash <> "$",
          fixture.hash <> "\n",
          " " <> fixture.hash,
          "pbkdf2_sha256$600000$#{String.duplicate("!", 24)}$#{digest64}",
          "pbkdf2_sha256$600000$#{salt64}$#{String.duplicate("!", 44)}"
        ] do
      assert Credentials.parse(fixture.username, hash) == {:error, :invalid_owner_credentials}
    end
  end

  test "rejects noncanonical padding bits and URL-safe alphabet", fixture do
    salt64 = Base.encode64(fixture.salt)
    digest64 = Base.encode64(fixture.digest)

    for hash <- [
          "pbkdf2_sha256$600000$#{noncanonical(salt64, 21)}$#{digest64}",
          "pbkdf2_sha256$600000$#{salt64}$#{noncanonical(digest64, 42)}",
          encode_hash(:binary.copy(<<255>>, 16), fixture.digest)
          |> String.replace("/", "_")
        ] do
      assert byte_size(hash) == 90
      assert Credentials.parse(fixture.username, hash) == {:error, :invalid_owner_credentials}
    end
  end

  test "validates binary UTF-8 byte bounds before derivation" do
    assert Credentials.valid_input?(String.duplicate("a", 64), String.duplicate("x", 1024))
    assert Credentials.valid_input?(String.duplicate("é", 32), String.duplicate("é", 512))
    assert Credentials.valid_input?("not a configured username", " password ")

    for {username, password} <- [
          {nil, "password"},
          {"owner", nil},
          {%{"nested" => "owner"}, "password"},
          {"owner", ["password"]},
          {"", "password"},
          {"owner", ""},
          {String.duplicate("a", 65), "password"},
          {"owner", String.duplicate("x", 1025)},
          {String.duplicate("é", 33), "password"},
          {"owner", String.duplicate("é", 513)},
          {<<255>>, "password"},
          {"owner", <<255>>}
        ] do
      refute Credentials.valid_input?(username, password)
    end
  end

  test "verifies exact username and password bytes", fixture do
    {:ok, credentials} = Credentials.parse(fixture.username, fixture.hash)

    assert Credentials.verify(credentials, fixture.username, fixture.password)
    refute Credentials.verify(credentials, String.upcase(fixture.username), fixture.password)
    refute Credentials.verify(credentials, fixture.username, String.trim(fixture.password))
    refute Credentials.verify(credentials, fixture.username, "different synthetic password")
    refute Credentials.verify(credentials, fixture.username, %{"password" => fixture.password})
    refute Credentials.verify(%{}, fixture.username, fixture.password)
  end

  test "wrong username still derives the fixed KDF and compares both fixed-size digests",
       fixture do
    {:ok, credentials} = Credentials.parse(fixture.username, fixture.hash)
    parent = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :verify ->
               result = Credentials.verify(credentials, "wrong-owner", fixture.password)
               send(parent, {:verified, result})
           end
         end}
      )

    :erlang.trace_pattern({:crypto, :pbkdf2_hmac, 5}, true, [:local])
    :erlang.trace_pattern({Plug.Crypto, :secure_compare, 2}, true, [:local])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({:crypto, :pbkdf2_hmac, 5}, false, [:local])
      :erlang.trace_pattern({Plug.Crypto, :secure_compare, 2}, false, [:local])
    end)

    send(worker, :verify)

    assert_receive {:trace, ^worker, :call,
                    {:crypto, :pbkdf2_hmac, [:sha256, password, salt, 600_000, 32]}},
                   1_000

    assert password == fixture.password
    assert salt == fixture.salt

    for _ <- 1..2 do
      assert_receive {:trace, ^worker, :call, {Plug.Crypto, :secure_compare, [left, right]}},
                     1_000

      assert byte_size(left) == 32
      assert byte_size(right) == 32
    end

    assert_receive {:verified, false}, 1_000
  end

  defp encode_hash(salt, digest) do
    "pbkdf2_sha256$600000$#{Base.encode64(salt)}$#{Base.encode64(digest)}"
  end

  defp noncanonical(encoded, index) do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    character = binary_part(encoded, index, 1)
    {position, 1} = :binary.match(alphabet, character)
    replacement = binary_part(alphabet, position + 1, 1)
    prefix = binary_part(encoded, 0, index)
    suffix = binary_part(encoded, index + 1, byte_size(encoded) - index - 1)
    prefix <> replacement <> suffix
  end
end
