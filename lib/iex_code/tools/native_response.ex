defmodule IexCode.Tools.NativeResponse do
  @moduledoc false
  @bytes 256_000
  @reserve 512

  def body_bytes, do: @bytes - @reserve

  # Slice before sanitizing/interpolating dynamic inputs, including error paths.
  def preview(text, limit \\ 256), do: bounded_text(text, limit)

  def compose(body, suffix) do
    bounded_text(body, body_bytes()) <> bounded_text(suffix, @reserve)
  end

  def envelope({status, text}) when status in [:ok, :error] and is_binary(text),
    do: {status, bounded_text(text, @bytes)}

  def envelope(other), do: other

  defp bounded_text(text, limit) do
    size = min(byte_size(text), limit)
    text |> binary_part(0, size) |> IexCode.Sessions.sanitize_utf8() |> trim_to(limit)
  end

  defp trim_to(text, limit) when byte_size(text) <= limit, do: text

  defp trim_to(text, limit),
    do: text |> binary_part(0, limit - 20) |> IexCode.Sessions.sanitize_utf8()
end
