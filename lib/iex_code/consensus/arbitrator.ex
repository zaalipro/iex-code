defmodule IexCode.Consensus.Arbitrator do
  @moduledoc """
  Multi-Model Consensus Arbitrator.
  Orchestrates panel reviews, enforces dynamic offline model weight renormalization,
  auto-approves high-concordance proposals, gates contested diffs behind RunApproval records,
  and manages human resolution of arbitration requests.
  """

  alias IexCode.Consensus.Matrix
  alias IexCode.Repo
  alias IexCode.Runs.RunApproval

  @doc """
  Arbitrates a collection of peer assessments against strict consensus thresholds.
  Renormalizes weights when offline models fail or timeout.
  """
  @spec arbitrate([term()], keyword()) :: map()
  def arbitrate(assessments, opts \\ []) when is_list(assessments) do
    run_id = Keyword.get(opts, :run_id)
    initial_weights = Keyword.get(opts, :initial_weights, %{})
    dedup? = Keyword.get(opts, :deduplicate_reviewers, true)

    active_reviewer_ids =
      assessments
      |> Enum.map(& &1.reviewer_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Dynamic Weight Renormalization (clamping negative weights to 0.0)
    active_weights =
      if is_map(initial_weights) and map_size(initial_weights) > 0 do
        filtered =
          initial_weights
          |> Map.take(active_reviewer_ids)
          |> Map.new(fn {k, v} -> {k, if(is_number(v), do: max(0.0, v * 1.0), else: 0.0)} end)

        sum = filtered |> Map.values() |> Enum.sum()

        if sum > 0.0 do
          Map.new(filtered, fn {k, v} -> {k, v / sum} end)
        else
          %{}
        end
      else
        %{}
      end

    matrix_opts =
      [weights: active_weights, deduplicate_reviewers: dedup?]
      |> maybe_put_opt(:dimension_weights, Keyword.get(opts, :dimension_weights))

    matrix_res = Matrix.compute(assessments, matrix_opts)

    case matrix_res.decision do
      :approved ->
        %{
          decision: :approved,
          auto_approved: true,
          approval_record: nil,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }

      :rejected ->
        %{
          decision: :rejected,
          auto_approved: false,
          approval_record: nil,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }

      :requires_arbitration ->
        approval =
          if run_id do
            key = "consensus_arbitration_#{Ecto.UUID.generate()}"

            attrs = %{
              run_id: run_id,
              key: key,
              action: "consensus_arbitration",
              reason: "Contested multi-model consensus requires arbitration",
              requested_by: "consensus_arbitrator",
              target_attempt: 0,
              target_generation: 0,
              status: "pending",
              metadata: %{
                decision: :requires_arbitration,
                weighted_score: matrix_res.weighted_score,
                swarm_concordance: matrix_res.swarm_concordance
              }
            }

            case %RunApproval{run_id: run_id}
                 |> RunApproval.changeset(attrs)
                 |> Repo.insert() do
              {:ok, app} -> %{app | status: :pending}
              {:error, _} -> nil
            end
          else
            nil
          end

        %{
          decision: :requires_arbitration,
          auto_approved: false,
          approval_record: approval,
          swarm_concordance: matrix_res.swarm_concordance,
          weighted_score: matrix_res.weighted_score,
          matrix: matrix_res
        }
    end
  end

  @doc """
  Resolves a pending consensus arbitration RunApproval record.
  Validates resolution strictly to `:approved | :rejected | "approved" | "rejected"`,
  is idempotent when re-resolved with the matching status, and rejects conflicting
  re-resolution with `{:error, :already_resolved}`.
  """
  @spec resolve_arbitration(String.t(), atom() | String.t()) ::
          {:ok, RunApproval.t()} | {:error, term()}
  def resolve_arbitration(approval_id, resolution) when is_binary(approval_id) do
    with {:ok, resolution_atom, status_str} <- normalize_resolution(resolution) do
      case Repo.get(RunApproval, approval_id) do
        nil ->
          {:error, :not_found}

        approval ->
          current_status = to_string(approval.status)

          cond do
            current_status == "pending" ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              changeset =
                RunApproval.changeset(approval, %{
                  status: status_str,
                  decided_at: now,
                  decided_by: "human_arbitrator"
                })

              case Repo.update(changeset) do
                {:ok, updated} -> {:ok, %{updated | status: resolution_atom}}
                {:error, reason} -> {:error, reason}
              end

            current_status == status_str ->
              {:ok, %{approval | status: resolution_atom}}

            true ->
              {:error, :already_resolved}
          end
      end
    end
  end

  def resolve_arbitration(_approval_id, _resolution), do: {:error, :invalid_resolution}

  @doc """
  Aggregates and deduplicates consensus critique points, identifies weakest rubric dimensions,
  and formats a crisp `repair_prompt` string ready to feed back into a coder retry turn.
  Accepts either a list of assessments, a `Matrix.compute/2` result map, or an `arbitrate/2` result map.
  """
  @spec synthesize_actionable_feedback(map() | [term()], keyword()) :: map()
  def synthesize_actionable_feedback(matrix_or_assessments, opts \\ [])

  def synthesize_actionable_feedback(assessments, opts)
      when is_list(assessments) and is_list(opts) do
    assessments
    |> Matrix.compute(opts)
    |> synthesize_actionable_feedback(opts)
  end

  def synthesize_actionable_feedback(%{matrix: %{} = matrix}, opts) when is_list(opts) do
    synthesize_actionable_feedback(matrix, opts)
  end

  def synthesize_actionable_feedback(%{assessments: assessments} = matrix, opts)
      when is_list(assessments) and is_list(opts) do
    matrix =
      if assessments != [] and map_size(Map.get(matrix, :dimensional_averages, %{})) == 0 do
        Matrix.compute(assessments, opts)
      else
        matrix
      end

    assessments = Map.get(matrix, :assessments, [])
    dimensional_averages = Map.get(matrix, :dimensional_averages, %{})
    threshold = Keyword.get(opts, :dimension_threshold, 0.80)
    max_weak = Keyword.get(opts, :max_weak_dimensions, 3)

    critique_items = aggregate_critiques(assessments)
    blocking_issues = Enum.filter(critique_items, &(&1.severity == :blocker))
    weakest_dimensions = identify_weakest_dimensions(dimensional_averages, threshold, max_weak)
    suggested_modifications = collect_suggested_modifications(assessments)

    repair_prompt =
      format_repair_prompt(
        matrix,
        assessments,
        blocking_issues,
        critique_items,
        weakest_dimensions,
        suggested_modifications,
        threshold
      )

    %{
      decision: Map.get(matrix, :decision, :requires_arbitration),
      reviewer_count: length(assessments),
      blocking_issues: blocking_issues,
      critique_items: critique_items,
      weakest_dimensions: weakest_dimensions,
      dimensional_averages: dimensional_averages,
      suggested_modifications: suggested_modifications,
      repair_prompt: repair_prompt
    }
  end

  def synthesize_actionable_feedback(_, opts) when is_list(opts) do
    synthesize_actionable_feedback([], opts)
  end

  defp normalize_resolution(:approved), do: {:ok, :approved, "approved"}
  defp normalize_resolution("approved"), do: {:ok, :approved, "approved"}
  defp normalize_resolution(:rejected), do: {:ok, :rejected, "rejected"}
  defp normalize_resolution("rejected"), do: {:ok, :rejected, "rejected"}
  defp normalize_resolution(_), do: {:error, :invalid_resolution}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp aggregate_critiques(assessments) do
    assessments
    |> Enum.with_index()
    |> Enum.flat_map(fn {assessment, idx} ->
      reviewer_label = reviewer_label(assessment, idx)
      conf = clamp_confidence(Map.get(assessment, :confidence, 1.0))

      (Map.get(assessment, :critique_points) || [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalize_critique_point(&1, reviewer_label, conf))
    end)
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.update(acc, entry.dedup_key, entry.item, fn existing ->
        merge_critique_items(existing, entry.item)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn item ->
      {
        -severity_rank(item.severity),
        -item.frequency,
        -item.confidence,
        item.file || "",
        item.line || 0,
        item.description
      }
    end)
  end

  defp normalize_critique_point(c, reviewer_label, conf) do
    severity = normalize_severity(fetch_any(c, [:severity, "severity"]))
    category = normalize_category(fetch_any(c, [:category, "category"]))
    file = normalize_file(fetch_any(c, [:file_path, "file_path", :file, "file"]))
    line = normalize_line(fetch_any(c, [:line_number, "line_number", :line, "line"]))

    description =
      c
      |> fetch_any([:description, "description", :message, "message"])
      |> to_trimmed_string()

    dedup_key =
      if is_nil(file) and is_nil(line) do
        {nil, nil, String.downcase(category), String.downcase(description)}
      else
        {file, line, String.downcase(category)}
      end

    item = %{
      severity: severity,
      category: category,
      file: file,
      line: line,
      description: description,
      frequency: 1,
      confidence: conf,
      reviewers: [reviewer_label]
    }

    %{dedup_key: dedup_key, item: item}
  end

  defp merge_critique_items(existing, incoming) do
    merged_severity =
      if severity_rank(incoming.severity) > severity_rank(existing.severity) do
        incoming.severity
      else
        existing.severity
      end

    merged_reviewers =
      Enum.uniq(existing.reviewers ++ incoming.reviewers)

    merged_description =
      merge_descriptions(existing.description, incoming.description)

    %{
      existing
      | severity: merged_severity,
        description: merged_description,
        reviewers: merged_reviewers,
        frequency: length(merged_reviewers),
        confidence: max(existing.confidence, incoming.confidence)
    }
  end

  defp merge_descriptions("", incoming), do: incoming
  defp merge_descriptions(existing, ""), do: existing

  defp merge_descriptions(existing, incoming) do
    ex_down = String.downcase(existing)
    in_down = String.downcase(incoming)

    cond do
      ex_down == in_down -> existing
      String.contains?(ex_down, in_down) -> existing
      String.contains?(in_down, ex_down) -> incoming
      true -> existing <> "; " <> incoming
    end
  end

  defp identify_weakest_dimensions(dimensional_averages, _threshold, _max_weak)
       when map_size(dimensional_averages) == 0,
       do: []

  defp identify_weakest_dimensions(dimensional_averages, threshold, max_weak) do
    dimensional_averages
    |> Enum.filter(fn {_dim, avg} -> is_number(avg) and avg < threshold end)
    |> Enum.sort_by(fn {dim, avg} -> {avg, to_string(dim)} end)
    |> Enum.take(max_weak)
    |> Enum.map(fn {dim, avg} ->
      %{dimension: dim, score: Float.round(avg * 1.0, 4)}
    end)
  end

  defp collect_suggested_modifications(assessments) do
    assessments
    |> Enum.flat_map(fn a -> Map.get(a, :suggested_modifications) || [] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp format_repair_prompt(
         _matrix,
         [],
         _blocking,
         _critiques,
         _weakest,
         _mods,
         _threshold
       ),
       do: ""

  defp format_repair_prompt(
         matrix,
         assessments,
         [],
         [],
         [],
         [],
         _threshold
       ) do
    decision = Map.get(matrix, :decision, :approved)

    if decision == :approved do
      "Consensus approved (score=#{format_score(Map.get(matrix, :weighted_score, 0.0))}, concordance=#{format_score(Map.get(matrix, :swarm_concordance, 0.0))}). No repairs required."
    else
      "Consensus #{decision} (score=#{format_score(Map.get(matrix, :weighted_score, 0.0))}, concordance=#{format_score(Map.get(matrix, :swarm_concordance, 0.0))}, reviewers=#{length(assessments)}). Review contested changes before proceeding."
    end
  end

  defp format_repair_prompt(
         matrix,
         assessments,
         blocking_issues,
         critique_items,
         weakest_dimensions,
         suggested_modifications,
         threshold
       ) do
    decision = Map.get(matrix, :decision, :requires_arbitration)
    score = Map.get(matrix, :weighted_score, 0.0)
    concordance = Map.get(matrix, :swarm_concordance, 0.0)

    header =
      "Consensus repair required (#{decision}, weighted_score=#{format_score(score)}, concordance=#{format_score(concordance)}, reviewers=#{length(assessments)}):"

    non_blockers = Enum.reject(critique_items, &(&1.severity == :blocker))

    sections =
      [header]
      |> maybe_add_section(
        "Blocking issues (must fix):",
        Enum.map(blocking_issues, &format_item/1)
      )
      |> maybe_add_section("Additional critique items:", Enum.map(non_blockers, &format_item/1))
      |> maybe_add_section(
        "Weakest rubric dimensions (< #{format_score(threshold)}):",
        Enum.map(weakest_dimensions, fn w -> "- #{w.dimension}: #{format_score(w.score)}" end)
      )
      |> maybe_add_section(
        "Suggested modifications:",
        Enum.map(suggested_modifications, fn mod -> "- #{mod}" end)
      )

    Enum.join(sections, "\n\n")
  end

  defp maybe_add_section(sections, _title, []), do: sections

  defp maybe_add_section(sections, title, lines) do
    sections ++ [Enum.join([title | lines], "\n")]
  end

  defp format_item(item) do
    tag = item.severity |> to_string() |> String.upcase()

    loc =
      case {item.file, item.line} do
        {nil, nil} -> "general"
        {file, nil} -> file
        {nil, line} -> "line #{line}"
        {file, line} -> "#{file}:#{line}"
      end

    desc = if item.description == "", do: "No description provided", else: item.description

    "- [#{tag}] #{loc} (#{item.category}) — #{desc} [#{item.frequency} reviewer(s), conf=#{format_score(item.confidence)}]"
  end

  defp format_score(val) when is_number(val), do: :erlang.float_to_binary(val * 1.0, decimals: 2)
  defp format_score(_), do: "0.00"

  defp severity_rank(:blocker), do: 3
  defp severity_rank(:major), do: 2
  defp severity_rank(:minor), do: 1
  defp severity_rank(_), do: 0

  defp normalize_severity(s) when s in [:blocker, "blocker"], do: :blocker
  defp normalize_severity(s) when s in [:major, "major"], do: :major
  defp normalize_severity(s) when s in [:minor, "minor"], do: :minor
  defp normalize_severity(_), do: :minor

  defp normalize_category(cat) when is_binary(cat) do
    case String.trim(cat) do
      "" -> "general"
      trimmed -> trimmed
    end
  end

  defp normalize_category(cat) when is_atom(cat) and not is_nil(cat), do: Atom.to_string(cat)
  defp normalize_category(_), do: "general"

  defp normalize_file(file) when is_binary(file) do
    case file |> String.trim() |> String.replace_leading("./", "") do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp normalize_file(_), do: nil

  defp normalize_line(line) when is_integer(line) and line > 0, do: line
  defp normalize_line(_), do: nil

  defp to_trimmed_string(val) when is_binary(val), do: String.trim(val)
  defp to_trimmed_string(_), do: ""

  defp reviewer_label(assessment, idx) do
    cond do
      is_binary(Map.get(assessment, :reviewer_id)) and
          String.trim(assessment.reviewer_id) != "" ->
        String.trim(assessment.reviewer_id)

      is_binary(Map.get(assessment, :model)) and String.trim(assessment.model) != "" ->
        "#{assessment.model}##{idx}"

      true ->
        "anonymous##{idx}"
    end
  end

  defp clamp_confidence(val) when is_number(val), do: (val * 1.0) |> max(0.0) |> min(1.0)
  defp clamp_confidence(_), do: 1.0

  defp fetch_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, val} when not is_nil(val) -> val
        _ -> nil
      end
    end)
  end
end
