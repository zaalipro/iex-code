defmodule IexCode.Tools.BoundedFile do
  @moduledoc """
  Fixed-chunk line scanning for native tools. Carries at most 64 KiB of one
  line plus a 16 KiB chunk; byte ceilings include read-ahead. Callbacks stop
  scanning immediately unless they request bounded validation-only continuation.
  Descriptors close on every exit.
  """

  @chunk_bytes 16_384
  @line_bytes 65_536
  @scan_bytes 2_097_152
  @output_bytes 256_000

  def limits do
    %{
      chunk_bytes: @chunk_bytes,
      line_bytes: @line_bytes,
      scan_bytes: @scan_bytes,
      output_bytes: @output_bytes
    }
  end

  def scan(path, acc, callback, opts \\ []) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        state = %{
          acc: acc,
          bytes: 0,
          lines: 0,
          reason: nil,
          collecting?: true,
          collection_reason: nil
        }

        read(
          file,
          "",
          "",
          state,
          callback,
          Keyword.get(opts, :byte_limit, @scan_bytes),
          Keyword.get(opts, :valid_utf8, false)
        )
      after
        File.close(file)
      end
    end
  end

  defp read(_file, _carry, _unicode_carry, state, _callback, limit, _utf8)
       when state.bytes >= limit,
       do: {:ok, %{state | reason: :scan}}

  defp read(file, carry, unicode_carry, state, callback, limit, utf8) do
    case IO.binread(file, min(@chunk_bytes, limit - state.bytes)) do
      :eof ->
        case if(utf8 and unicode_carry != "",
               do: {:error, :invalid_utf8},
               else: line(carry, state, callback, utf8)
             ) do
          {:cont, state} ->
            {:ok, state}

          {:halt, %{reason: reason} = state} when reason in [:line_limit, :matches] ->
            {:ok, %{state | reason: nil}}

          {:halt, state} ->
            {:ok, state}

          {:error, reason} ->
            {:error, reason, state.bytes}
        end

      {:error, reason} ->
        {:error, reason, state.bytes}

      chunk ->
        state = %{state | bytes: state.bytes + byte_size(chunk)}

        with {:ok, unicode_carry} <- validate_chunk(unicode_carry <> chunk, utf8) do
          case consume(carry <> chunk, state, callback, utf8) do
            {:cont, carry, state} ->
              read(file, carry, unicode_carry, state, callback, limit, utf8)

            {:halt, state} ->
              {:ok, state}

            {:error, reason} ->
              {:error, reason, state.bytes}
          end
        else
          {:error, reason} -> {:error, reason, state.bytes}
        end
    end
  end

  defp validate_chunk(_chunk, false), do: {:ok, ""}

  defp validate_chunk(chunk, true) do
    case :unicode.characters_to_binary(chunk, :utf8, :utf8) do
      binary when is_binary(binary) -> {:ok, ""}
      {:incomplete, _valid, rest} -> {:ok, :binary.copy(rest)}
      {:error, _valid, _rest} -> {:error, :invalid_utf8}
    end
  end

  defp consume(data, state, callback, utf8) do
    case :binary.match(data, "\n") do
      {size, 1} when size <= @line_bytes ->
        <<text::binary-size(size), "\n", rest::binary>> = data

        text =
          if not utf8 and String.ends_with?(text, "\r"),
            do: binary_part(text, 0, byte_size(text) - 1),
            else: text

        case line(text, state, callback, utf8) do
          {:cont, state} -> consume(rest, state, callback, utf8)
          other -> other
        end

      :nomatch when byte_size(data) <= @line_bytes ->
        {:cont, :binary.copy(data), state}

      _ ->
        {:halt, %{state | reason: :giant_line}}
    end
  end

  defp line(text, state, callback, utf8) do
    if utf8 and not String.valid?(text) do
      {:error, :invalid_utf8}
    else
      state = %{state | lines: state.lines + 1}

      result =
        if state.collecting?,
          do: callback.(text, state.lines, state.acc),
          else: {:cont, state.acc}

      case result do
        {:cont, acc} ->
          {:cont, %{state | acc: acc}}

        {:halt, reason, acc} ->
          {:halt, %{state | acc: acc, reason: reason}}

        {:validate, reason, acc} ->
          {:cont,
           %{state | acc: acc, reason: reason, collecting?: false, collection_reason: reason}}
      end
    end
  end
end
