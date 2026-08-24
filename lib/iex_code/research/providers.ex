defmodule IexCode.Research.Providers do
  @moduledoc false

  alias IexCode.Research.Result

  def results(provider, rows, mapper) when is_list(rows) do
    rows
    |> Enum.map(mapper)
    |> Enum.map(&Result.new(provider, &1))
    |> Enum.reject(&is_nil/1)
  end

  def results(_provider, _rows, _mapper), do: []

  def api_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  def text(nil), do: nil
  def text(value) when is_binary(value), do: value
  def text(value) when is_list(value), do: Enum.join(value, " … ")
  def text(value), do: to_string(value)
end
