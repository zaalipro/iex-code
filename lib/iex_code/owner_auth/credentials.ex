defmodule IexCode.OwnerAuth.Credentials do
  @moduledoc false

  @algorithm "pbkdf2_sha256"
  @iterations 600_000
  @salt_bytes 16
  @digest_bytes 32
  @max_username_bytes 64
  @max_password_bytes 1_024

  @type t :: %{
          username_digest: <<_::256>>,
          salt: <<_::128>>,
          digest: <<_::256>>
        }

  @spec parse(term(), term()) :: {:ok, t()} | {:error, :invalid_owner_credentials}
  def parse(username, hash) when is_binary(username) and is_binary(hash) do
    with true <- valid_configured_username?(username),
         true <- byte_size(hash) == 90,
         [@algorithm, "600000", salt64, digest64] <- String.split(hash, "$", parts: 4),
         true <- byte_size(salt64) == 24,
         true <- byte_size(digest64) == 44,
         {:ok, salt} <- Base.decode64(salt64),
         {:ok, digest} <- Base.decode64(digest64),
         true <- byte_size(salt) == @salt_bytes,
         true <- byte_size(digest) == @digest_bytes,
         true <- Base.encode64(salt) == salt64,
         true <- Base.encode64(digest) == digest64 do
      {:ok,
       %{
         username_digest: :crypto.hash(:sha256, username),
         salt: salt,
         digest: digest
       }}
    else
      _ -> {:error, :invalid_owner_credentials}
    end
  end

  def parse(_username, _hash), do: {:error, :invalid_owner_credentials}

  @spec valid_input?(term(), term()) :: boolean()
  def valid_input?(username, password)
      when is_binary(username) and is_binary(password) do
    byte_size(username) in 1..@max_username_bytes and
      byte_size(password) in 1..@max_password_bytes and
      String.valid?(username) and String.valid?(password)
  end

  def valid_input?(_username, _password), do: false

  @spec verify(t(), term(), term()) :: boolean()
  def verify(credentials, username, password)
      when is_map(credentials) and is_binary(username) and is_binary(password) do
    if valid_input?(username, password) and valid_credentials?(credentials) do
      username_digest = :crypto.hash(:sha256, username)
      derived_digest = derive(password, credentials.salt)
      username_match = Plug.Crypto.secure_compare(credentials.username_digest, username_digest)
      password_match = Plug.Crypto.secure_compare(credentials.digest, derived_digest)
      username_match and password_match
    else
      false
    end
  end

  def verify(_credentials, _username, _password), do: false

  @doc false
  @spec derive(binary(), binary()) :: <<_::256>>
  def derive(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @digest_bytes)
  end

  @doc false
  @spec matches?(t(), binary(), binary()) :: boolean()
  def matches?(credentials, username_digest, derived_digest)
      when is_map(credentials) and is_binary(username_digest) and is_binary(derived_digest) do
    if valid_credentials?(credentials) and byte_size(username_digest) == 32 and
         byte_size(derived_digest) == 32 do
      username_match = Plug.Crypto.secure_compare(credentials.username_digest, username_digest)
      password_match = Plug.Crypto.secure_compare(credentials.digest, derived_digest)
      username_match and password_match
    else
      false
    end
  end

  def matches?(_credentials, _username_digest, _derived_digest), do: false

  defp valid_configured_username?(username) do
    byte_size(username) in 1..@max_username_bytes and
      String.valid?(username) and
      username
      |> :binary.bin_to_list()
      |> Enum.all?(fn byte ->
        (byte >= ?A and byte <= ?Z) or
          (byte >= ?a and byte <= ?z) or
          (byte >= ?0 and byte <= ?9) or
          byte in [?_, ?., ?@, ?-]
      end)
  end

  defp valid_credentials?(%{
         username_digest: username_digest,
         salt: salt,
         digest: digest
       })
       when is_binary(username_digest) and byte_size(username_digest) == 32 and
              is_binary(salt) and byte_size(salt) == @salt_bytes and
              is_binary(digest) and byte_size(digest) == @digest_bytes,
       do: true

  defp valid_credentials?(_), do: false
end
