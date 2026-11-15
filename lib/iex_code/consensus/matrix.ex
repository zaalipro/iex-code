defmodule IexCode.Consensus.Matrix do
  @moduledoc """
  Mathematical Consensus Matrix & Swarm Voting Engine.
  Computes pairwise agreement A_{j,k}, swarm concordance \bar{A}, weighted confidence score C,
  and enforces strict multi-model decision rule thresholds (:approved, :rejected, :requires_arbitration).
  """

  alias IexCode.Consensus.Assessment

  @dimensions [:correctness, :security, :architectural_fit, :maintainability, :testability]
  @default_weights %{
    correctness: 0.2,
    security: 0.2,
    architectural_fit: 0.2,
    maintainability: 0.2,
    testability: 0.2
  }

  @doc """
  Returns the default uniform dimension weights across the 5 rubric dimensions.
  """
  @spec default_weights() :: map()
  def default_weights, do: @default_weights

  @doc """
  Computes vote concordance between two assessments:
  - same vote: 1.0
  - approve vs reject: 0.0
  - approve vs request_changes: 0.25
  - reject vs request_changes: 0.75
  """
  @spec vote_concordance(Assessment.t(), Assessment.t()) :: float()
  def vote_concordance(%{vote: v1}, %{vote: v2}) do
    cond do
      v1 == v2 ->
        1.0

      (v1 == :approve and v2 == :reject) or (v1 == :reject and v2 == :approve) ->
        0.0

      (v1 == :approve and v2 == :request_changes) or (v1 == :request_changes and v2 == :approve) ->
        0.25

      (v1 == :reject and v2 == :request_changes) or (v1 == :request_changes and v2 == :reject) ->
        0.75

      true ->
        0.0
    end
  end

  @doc """
  Computes pairwise agreement A_{j,k} between two assessments satisfying:
  - Reflexivity: A_{j,j} == 1.0
  - Symmetry: A_{j,k} == A_{k,j}
  - Boundedness: 0.0 <= A_{j,k} <= 1.0
  Formula: A_{j,k} = 0.60 * vote_concordance + 0.40 * (1.0 - norm_diff / sqrt(5))
  """
  @spec pairwise_agreement(Assessment.t(), Assessment.t()) :: float()
  def pairwise_agreement(a, b) do
    pairwise_agreement(a, b, @default_weights)
  end

  @spec pairwise_agreement(Assessment.t(), Assessment.t(), map()) :: float()
  def pairwise_agreement(a, b, dim_weights) when is_map(dim_weights) do
    scores_a = clamp_scores(Map.get(a, :scores))
    scores_b = clamp_scores(Map.get(b, :scores))

    if a.reviewer_id == b.reviewer_id and a.vote == b.vote and scores_a == scores_b do
      1.0
    else
      delta_vote = vote_concordance(a, b)
      norm_weights = normalize_dimension_weights(dim_weights)

      weighted_diff_sq_sum =
        Enum.reduce(@dimensions, 0.0, fn dim, acc ->
          s1 = Map.fetch!(scores_a, dim)
          s2 = Map.fetch!(scores_b, dim)
          w = Map.get(norm_weights, dim, 0.2)
          diff = s1 - s2
          acc + w * diff * diff
        end)

      weighted_dist = :math.sqrt(weighted_diff_sq_sum)
      score_agreement = max(0.0, 1.0 - weighted_dist)

      agreement = 0.60 * delta_vote + 0.40 * score_agreement
      clamp(agreement, 0.0, 1.0)
    end
  end

  @doc """
  Computes the full consensus matrix, swarm concordance, weighted score, and arbitration decision.
  """
  @spec compute([Assessment.t()], keyword()) :: map()
  def compute(assessments, opts \\ [])

  def compute([], _opts) do
    empty_result()
  end

  def compute(assessments, opts) when is_list(assessments) do
    dedup? = Keyword.get(opts, :deduplicate_reviewers, true)
    assessments = deduplicate_assessments(assessments, dedup?)

    if assessments == [] do
      empty_result()
    else
      do_compute(assessments, opts)
    end
  end

  defp empty_result do
    %{
      decision: :requires_arbitration,
      weighted_score: 0.0,
      swarm_concordance: 0.0,
      dimensional_averages: %{},
      pairwise_matrix: [],
      has_blocker?: false,
      assessments: []
    }
  end

  defp do_compute(assessments, opts) do
    m = length(assessments)
    weights_opt = Keyword.get(opts, :weights, %{})
    dim_weights_opt = Keyword.get(opts, :dimension_weights)

    {reviewer_weights_opt, inferred_dim_weights} =
      partition_weights_opt(assessments, weights_opt, dim_weights_opt)

    dim_weights = normalize_dimension_weights(inferred_dim_weights)

    # 1. Normalized reviewer weights (clamping negatives to 0.0, falling back to uniform if sum == 0)
    raw_weights =
      if is_map(reviewer_weights_opt) and map_size(reviewer_weights_opt) > 0 do
        Enum.map(assessments, fn a ->
          rev_id = a.reviewer_id || "reviewer"

          reviewer_weights_opt
          |> Map.get(rev_id, 1.0)
          |> non_neg_float(0.0)
        end)
      else
        List.duplicate(1.0, m)
      end

    sum_w = Enum.sum(raw_weights)

    normalized_weights =
      if sum_w > 0.0 do
        Enum.map(raw_weights, &(&1 / sum_w))
      else
        List.duplicate(1.0 / m, m)
      end

    # 2. Pairwise agreement matrix
    matrix_grid =
      for a <- assessments do
        for b <- assessments do
          pairwise_agreement(a, b, dim_weights)
        end
      end

    # 3. Swarm concordance \bar{A}
    swarm_concordance =
      if m == 1 do
        1.0
      else
        pairs =
          for j <- 0..(m - 2), k <- (j + 1)..(m - 1) do
            pairwise_agreement(Enum.at(assessments, j), Enum.at(assessments, k), dim_weights)
          end

        clamp(Enum.sum(pairs) / length(pairs), 0.0, 1.0)
      end

    # 4. Weighted score C (bounded in [-1.0, 1.0])
    weighted_score =
      assessments
      |> Enum.zip(normalized_weights)
      |> Enum.reduce(0.0, fn {a, w}, acc ->
        v_val = vote_value(a.vote)
        conf = clamp_unit(a.confidence, 1.0)
        acc + w * conf * v_val
      end)
      |> clamp(-1.0, 1.0)

    # 5. Dimensional averages \bar{S} (bounded in [0.0, 1.0])
    dimensional_averages =
      Enum.reduce(@dimensions, %{}, fn dim, acc ->
        avg =
          assessments
          |> Enum.zip(normalized_weights)
          |> Enum.reduce(0.0, fn {a, w}, d_acc ->
            d_acc + w * dimension_score(a, dim)
          end)
          |> clamp(0.0, 1.0)

        Map.put(acc, dim, avg)
      end)

    # 6. Blocker critique detection
    has_blocker? =
      Enum.any?(assessments, fn a ->
        Enum.any?(a.critique_points || [], fn c ->
          c[:severity] in [:blocker, "blocker"] or c["severity"] in [:blocker, "blocker"]
        end)
      end)

    # 7. Decision rule evaluation
    decision =
      cond do
        has_blocker? ->
          if weighted_score <= -0.40 or Map.get(dimensional_averages, :security, 1.0) < 0.5 do
            :rejected
          else
            :requires_arbitration
          end

        weighted_score >= 0.65 and swarm_concordance >= 0.60 and
            Map.get(dimensional_averages, :security, 1.0) >= 0.70 ->
          :approved

        weighted_score <= -0.40 ->
          :rejected

        true ->
          :requires_arbitration
      end

    %{
      decision: decision,
      weighted_score: weighted_score,
      swarm_concordance: swarm_concordance,
      dimensional_averages: dimensional_averages,
      pairwise_matrix: matrix_grid,
      has_blocker?: has_blocker?,
      assessments: assessments
    }
  end

  defp deduplicate_assessments(assessments, false), do: assessments

  defp deduplicate_assessments(assessments, _true) do
    assessments
    |> Enum.with_index()
    |> Enum.uniq_by(fn {assessment, idx} ->
      case Map.get(assessment, :reviewer_id) do
        id when is_binary(id) ->
          trimmed = String.trim(id)
          if trimmed == "", do: {:anonymous, idx}, else: {:reviewer, trimmed}

        nil ->
          {:anonymous, idx}

        other ->
          {:reviewer, other}
      end
    end)
    |> Enum.map(fn {assessment, _idx} -> assessment end)
  end

  defp partition_weights_opt(assessments, weights_opt, dim_weights_opt) do
    cond do
      is_map(dim_weights_opt) ->
        {weights_opt, dim_weights_opt}

      is_map(weights_opt) and map_size(weights_opt) > 0 and
          dimension_weight_map?(weights_opt, assessments) ->
        {%{}, weights_opt}

      true ->
        {weights_opt, @default_weights}
    end
  end

  defp dimension_weight_map?(map, assessments) do
    dim_keys = MapSet.new(@dimensions ++ Enum.map(@dimensions, &Atom.to_string/1))

    reviewer_ids =
      assessments
      |> Enum.map(& &1.reviewer_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    keys = Map.keys(map)

    Enum.all?(keys, &MapSet.member?(dim_keys, &1)) and
      not Enum.any?(keys, &MapSet.member?(reviewer_ids, &1))
  end

  defp normalize_dimension_weights(dim_weights) when is_map(dim_weights) do
    clamped =
      Enum.reduce(@dimensions, %{}, fn dim, acc ->
        raw =
          case Map.fetch(dim_weights, dim) do
            {:ok, v} -> v
            :error -> Map.get(dim_weights, Atom.to_string(dim), 0.0)
          end

        Map.put(acc, dim, non_neg_float(raw, 0.0))
      end)

    total = clamped |> Map.values() |> Enum.sum()

    if total > 0.0 do
      Map.new(clamped, fn {dim, w} -> {dim, w / total} end)
    else
      @default_weights
    end
  end

  defp normalize_dimension_weights(_), do: @default_weights

  defp clamp_scores(scores) when is_map(scores) do
    Enum.reduce(@dimensions, %{}, fn dim, acc ->
      Map.put(acc, dim, dimension_score_from_map(scores, dim))
    end)
  end

  defp clamp_scores(_), do: clamp_scores(%{})

  defp dimension_score(assessment, dim) do
    scores = Map.get(assessment, :scores) || %{}
    dimension_score_from_map(scores, dim)
  end

  defp dimension_score_from_map(scores, dim) when is_map(scores) do
    raw =
      case fetch_score(scores, dim) do
        nil when dim == :testability -> fetch_score(scores, :test_coverage)
        val -> val
      end

    clamp_unit(raw, 0.8)
  end

  defp dimension_score_from_map(_, _), do: 0.8

  defp fetch_score(scores, dim) do
    case Map.fetch(scores, dim) do
      {:ok, val} when not is_nil(val) -> val
      _ -> Map.get(scores, Atom.to_string(dim))
    end
  end

  defp clamp_unit(val, _default) when is_number(val), do: clamp(val * 1.0, 0.0, 1.0)
  defp clamp_unit(_, default), do: default

  defp non_neg_float(val, _default) when is_number(val), do: max(0.0, val * 1.0)
  defp non_neg_float(_, default), do: default

  defp vote_value(:approve), do: 1.0
  defp vote_value(:reject), do: -1.0
  defp vote_value(:request_changes), do: -0.25
  defp vote_value(_), do: 0.0

  defp clamp(val, min_val, _max_val) when val < min_val, do: min_val
  defp clamp(val, _min_val, max_val) when val > max_val, do: max_val
  defp clamp(val, _min_val, _max_val), do: val
end
