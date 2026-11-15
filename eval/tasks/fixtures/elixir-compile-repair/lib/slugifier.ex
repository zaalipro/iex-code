defmodule Slugifier do
  @moduledoc """
  URL slug normalization helper.
  """

  @spec slugify(String.t()) :: String.t()
  def slugify(input) when is_binary(input) do
    input
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "-")
end
