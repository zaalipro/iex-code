defmodule IexCode.Consensus.Assessment do
  @moduledoc """
  Structured code assessment from an individual reviewer (Cloud or Local model).
  Includes vote (:approve, :reject, :request_changes), confidence, dimensional scores,
  verdict reasoning, critique points, and suggested modifications.
  """

  @enforce_keys [:vote, :confidence]
  defstruct [
    :reviewer_id,
    :provider,
    :model,
    :vote,
    :confidence,
    scores: %{
      correctness: 0.8,
      security: 0.8,
      architectural_fit: 0.8,
      maintainability: 0.8,
      testability: 0.8
    },
    verdict_reason: "",
    critique_points: [],
    suggested_modifications: []
  ]

  @type vote :: :approve | :reject | :request_changes
  @type t :: %__MODULE__{
          reviewer_id: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          vote: vote(),
          confidence: float(),
          scores: %{
            correctness: float(),
            security: float(),
            architectural_fit: float(),
            maintainability: float(),
            testability: float()
          },
          verdict_reason: String.t(),
          critique_points: [map()],
          suggested_modifications: [String.t()]
        }

  @doc """
  Parses a JSON string, a markdown-wrapped codeblock, or a map into an Assessment struct.
  """
  @spec parse(String.t() | map()) :: {:ok, t()} | {:error, term()}
  def parse(input) when is_binary(input) do
    cleaned = extract_json(input)

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        parse(map)

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  def parse(%{} = map) do
    vote = normalize_vote(fetch_any(map, ["vote", :vote]))

    confidence =
      map |> fetch_any(["confidence", :confidence]) |> parse_float(1.0) |> clamp(0.0, 1.0)

    raw_scores =
      case fetch_any(map, ["scores", :scores]) do
        s when is_map(s) -> s
        _ -> %{}
      end

    scores = %{
      correctness:
        raw_scores
        |> fetch_any(["correctness", :correctness])
        |> parse_float(0.8)
        |> clamp(0.0, 1.0),
      security:
        raw_scores
        |> fetch_any(["security", :security])
        |> parse_float(0.8)
        |> clamp(0.0, 1.0),
      architectural_fit:
        raw_scores
        |> fetch_any(["architectural_fit", :architectural_fit])
        |> parse_float(0.8)
        |> clamp(0.0, 1.0),
      maintainability:
        raw_scores
        |> fetch_any(["maintainability", :maintainability])
        |> parse_float(0.8)
        |> clamp(0.0, 1.0),
      testability:
        raw_scores
        |> fetch_any(["testability", :testability, "test_coverage", :test_coverage])
        |> parse_float(0.8)
        |> clamp(0.0, 1.0)
    }

    critique_points =
      case fetch_any(map, ["critique_points", :critique_points]) do
        list when is_list(list) -> Enum.map(list, &normalize_critique/1)
        _ -> []
      end

    suggested_modifications =
      case fetch_any(map, ["suggested_modifications", :suggested_modifications]) do
        list when is_list(list) -> list
        _ -> []
      end

    verdict_reason =
      case fetch_any(map, ["verdict_reason", :verdict_reason]) do
        reason when is_binary(reason) -> reason
        _ -> ""
      end

    assessment = %__MODULE__{
      reviewer_id: fetch_any(map, ["reviewer_id", :reviewer_id]),
      provider: fetch_any(map, ["provider", :provider]),
      model: fetch_any(map, ["model", :model]),
      vote: vote,
      confidence: confidence,
      scores: scores,
      verdict_reason: verdict_reason,
      critique_points: critique_points,
      suggested_modifications: suggested_modifications
    }

    {:ok, assessment}
  rescue
    e -> {:error, e}
  end

  def to_map(%__MODULE__{} = a) do
    %{
      "reviewer_id" => a.reviewer_id,
      "provider" => a.provider,
      "model" => a.model,
      "vote" => to_string(a.vote),
      "confidence" => a.confidence,
      "scores" => a.scores,
      "verdict_reason" => a.verdict_reason,
      "critique_points" => a.critique_points,
      "suggested_modifications" => a.suggested_modifications
    }
  end

  defp extract_json(str) do
    str = String.trim(str)

    cond do
      Regex.match?(~r/```(?:json)?\s*([\s\S]*?)\s*```/i, str) ->
        [_, json] = Regex.run(~r/```(?:json)?\s*([\s\S]*?)\s*```/i, str)
        String.trim(json)

      String.starts_with?(str, "{") and String.ends_with?(str, "}") ->
        str

      true ->
        case {String.split(str, "{", parts: 2), String.split(str, "}")} do
          {[_, rest], _} ->
            "{" <> Enum.join(Enum.slice(String.split(rest, "}"), 0..-2//1), "}") <> "}"

          _ ->
            str
        end
    end
  end

  defp normalize_vote(v) when v in [:approve, "approve", "approved"], do: :approve
  defp normalize_vote(v) when v in [:reject, "reject", "rejected"], do: :reject

  defp normalize_vote(v) when v in [:request_changes, "request_changes", "changes_requested"],
    do: :request_changes

  defp normalize_vote(_), do: :request_changes

  defp parse_float(num, _default) when is_float(num), do: num
  defp parse_float(num, _default) when is_integer(num), do: num * 1.0

  defp parse_float(str, default) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp normalize_critique(%{} = c) do
    severity =
      case fetch_any(c, ["severity", :severity]) do
        s when s in [:blocker, "blocker"] -> :blocker
        s when s in [:minor, "minor"] -> :minor
        s when s in [:major, "major"] -> :major
        _ -> :minor
      end

    %{
      severity: severity,
      category: fetch_any(c, ["category", :category]) || "general",
      file_path: fetch_any(c, ["file_path", :file_path, "file", :file]),
      line_number: fetch_any(c, ["line_number", :line_number, "line", :line]),
      description: fetch_any(c, ["description", :description, "message", :message]) || ""
    }
  end

  defp normalize_critique(other), do: other

  defp fetch_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, val} when not is_nil(val) -> val
        _ -> nil
      end
    end)
  end

  defp clamp(val, min_val, _max_val) when val < min_val, do: min_val
  defp clamp(val, _min_val, max_val) when val > max_val, do: max_val
  defp clamp(val, _min_val, _max_val), do: val
end
