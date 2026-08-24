defmodule IexCode.Research.Result do
  @moduledoc """
  Provider-independent search result.

  `metadata` deliberately retains provider-specific fields while the other
  fields give callers a stable shape to rank, render, and cite.
  """

  @enforce_keys [:provider, :title, :url]
  defstruct [:provider, :title, :url, :snippet, :published_at, :score, metadata: %{}]

  @type t :: %__MODULE__{
          provider: String.t(),
          title: String.t(),
          url: String.t(),
          snippet: String.t() | nil,
          published_at: String.t() | nil,
          score: number() | nil,
          metadata: map()
        }

  @doc false
  def new(provider, attrs) when (is_atom(provider) or is_binary(provider)) and is_map(attrs) do
    title = value(attrs, :title) |> clean()
    url = value(attrs, :url) |> clean()

    if title && url do
      %__MODULE__{
        provider: to_string(provider),
        title: title,
        url: url,
        snippet: value(attrs, :snippet) |> clean(),
        published_at: value(attrs, :published_at) |> clean(),
        score: normalize_score(value(attrs, :score)),
        metadata: value(attrs, :metadata) || %{}
      }
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp clean(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp clean(_value), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp normalize_score(value) when is_number(value), do: value
  defp normalize_score(_value), do: nil
end
