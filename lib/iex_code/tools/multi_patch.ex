defmodule IexCode.Tools.MultiPatch do
  @moduledoc """
  Multi-File Atomic Patching Engine.
  Applies batch patches across multiple workspace files using a 3-tier matching
  strategy (AST, Exact, Fuzzy Indentation Alignment) with atomic transactional
  rollback on any failure.
  """

  alias IexCode.Tools.MultiPatch.{Matcher, Diff, Snapshot}

  @type tier :: Matcher.tier()

  @type patch_spec :: %{
          required(:path) => Path.t(),
          required(:target) => String.t(),
          required(:replacement) => String.t(),
          optional(:tier) => tier() | :auto,
          optional(:allow_multiple) => boolean()
        }

  @type patch_result :: %{
          path: Path.t(),
          tier_used: tier(),
          original_content: String.t(),
          new_content: String.t(),
          diff: String.t()
        }

  @type patch_summary :: %{
          applied: non_neg_integer(),
          patches: [patch_result()],
          diff: String.t(),
          tiers_used: %{
            ast: non_neg_integer(),
            exact: non_neg_integer(),
            fuzzy: non_neg_integer()
          },
          transaction_id: String.t()
        }

  @doc """
  Applies a batch of patches atomically across multiple workspace files.
  If any patch fails (target not found, syntax error, or write error),
  no files remain modified and all partial changes are rolled back.
  """
  @spec apply_patches(Path.t(), [patch_spec() | map()], keyword()) ::
          {:ok, patch_summary()} | {:error, term()}
  def apply_patches(project_root, patches, opts \\ []) when is_list(patches) do
    # Phase 1: In-Memory Validation & Plan (Zero disk writes)
    case plan_patches(project_root, patches, opts) do
      {:ok, planned_patches} ->
        # Phase 2: Transactional Disk Writes with Rollback Guard
        tx_id = "tx_" <> to_string(System.system_time(:microsecond))
        execute_writes(project_root, planned_patches, tx_id)

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Previews a batch of patches without modifying disk.
  Returns the unified diff and planned patch modifications.
  """
  @spec preview_patches(Path.t(), [patch_spec() | map()], keyword()) ::
          {:ok, %{diff: String.t(), patches: [patch_result()]}} | {:error, term()}
  def preview_patches(project_root, patches, opts \\ []) when is_list(patches) do
    case plan_patches(project_root, patches, opts) do
      {:ok, planned_patches} ->
        combined_diff =
          planned_patches
          |> Enum.map(& &1.diff)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        {:ok, %{diff: combined_diff, patches: planned_patches}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Patches a single string in memory using the 3-tier matcher.
  """
  @spec patch_string(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), tier: tier()}} | {:error, :not_found}
  defdelegate patch_string(content, target, replacement, opts \\ []), to: Matcher, as: :patch

  @doc """
  Reverts a previously applied patch transaction using its transaction ID.
  """
  @spec rollback(String.t()) ::
          {:ok, %{restored_files: [Path.t()]}} | {:error, term()}
  def rollback(transaction_id) do
    case Snapshot.get_snapshot(transaction_id) do
      {:ok, %{patches: patches}} ->
        restored =
          Enum.map(patches, fn p ->
            full_path = p.full_path

            if p.file_existed? do
              File.write!(full_path, p.original_content)
            else
              File.rm(full_path)
            end

            p.path
          end)

        Snapshot.delete_snapshot(transaction_id)
        {:ok, %{restored_files: restored}}

      {:error, :not_found} ->
        {:error, {:transaction_not_found, transaction_id}}
    end
  end

  # --- Phase 1: Planning & Validation ---

  defp plan_patches(project_root, patches, opts) do
    validate_syntax? = Keyword.get(opts, :validate_syntax, true)

    # Group patches by path so multiple patches to the same file are applied sequentially in memory
    normalized_patches = Enum.map(patches, &normalize_patch_spec/1)

    grouped =
      Enum.group_by(normalized_patches, fn p -> p.path end)

    Enum.reduce_while(grouped, {:ok, []}, fn {rel_path, file_patches}, {:ok, acc} ->
      full_path = resolve_file_path(project_root, rel_path)

      if not File.exists?(full_path) do
        {:halt, {:error, {:file_not_found, rel_path}}}
      else
        original_content = File.read!(full_path)

        # Apply patches sequentially in memory to original_content
        res =
          Enum.reduce_while(file_patches, {:ok, original_content, []}, fn patch,
                                                                          {:ok, current_content,
                                                                           patch_acc} ->
            target = patch.target
            replacement = patch.replacement

            patch_opts = [
              allow_multiple: patch.allow_multiple,
              tier: patch.tier
            ]

            case Matcher.patch(current_content, target, replacement, patch_opts) do
              {:ok, %{content: next_content, tier: tier_used}} ->
                {:cont, {:ok, next_content, [{patch, tier_used} | patch_acc]}}

              {:error, :not_found} ->
                {:halt, {:error, {:target_not_found, rel_path, target}}}
            end
          end)

        case res do
          {:ok, final_content, applied_info} ->
            # Validate Elixir syntax if requested
            ext = Path.extname(rel_path)

            syntax_check =
              if validate_syntax? and ext in [".ex", ".exs"] do
                case Code.string_to_quoted(final_content) do
                  {:ok, _ast} -> :ok
                  {:error, reason} -> {:error, {:syntax_error, rel_path, inspect(reason)}}
                end
              else
                :ok
              end

            case syntax_check do
              :ok ->
                diff_str = Diff.unified_diff(original_content, final_content, rel_path)
                # Determine predominant tier
                tiers = Enum.map(applied_info, fn {_p, t} -> t end)
                primary_tier = List.first(tiers) || :exact

                entry = %{
                  path: rel_path,
                  full_path: full_path,
                  file_existed?: true,
                  original_content: original_content,
                  new_content: final_content,
                  tier_used: primary_tier,
                  all_tiers: tiers,
                  diff: diff_str
                }

                {:cont, {:ok, [entry | acc]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      {:error, _} = err -> err
    end
  end

  # --- Phase 2: Transactional Execution ---

  defp execute_writes(_project_root, planned_patches, tx_id) do
    Enum.reduce_while(planned_patches, {:ok, []}, fn plan, {:ok, written} ->
      File.mkdir_p!(Path.dirname(plan.full_path))

      case File.write(plan.full_path, plan.new_content) do
        :ok ->
          {:cont, {:ok, [plan | written]}}

        {:error, reason} ->
          # Immediate Rollback
          for w <- written do
            if w.file_existed? do
              File.write!(w.full_path, w.original_content)
            else
              File.rm(w.full_path)
            end
          end

          {:halt, {:error, {:write_failed, plan.path, reason, :rolled_back}}}
      end
    end)
    |> case do
      {:ok, written_plans} ->
        # Save snapshot
        Snapshot.save_snapshot(tx_id, planned_patches)

        # Count tier breakdowns
        all_tiers = Enum.flat_map(planned_patches, & &1.all_tiers)

        ast_count = Enum.count(all_tiers, &(&1 == :ast))
        exact_count = Enum.count(all_tiers, &(&1 == :exact))
        fuzzy_count = Enum.count(all_tiers, &(&1 == :fuzzy))

        combined_diff =
          planned_patches
          |> Enum.map(& &1.diff)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")

        summary = %{
          applied: length(written_plans),
          patches: planned_patches,
          diff: combined_diff,
          tiers_used: %{
            ast: ast_count,
            exact: exact_count,
            fuzzy: fuzzy_count
          },
          transaction_id: tx_id
        }

        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_patch_spec(map) do
    path = Map.get(map, :path) || Map.get(map, "path")

    target =
      Map.get(map, :target) ||
        Map.get(map, "target") ||
        Map.get(map, :target_content) ||
        Map.get(map, "target_content") ||
        ""

    replacement =
      Map.get(map, :replacement) ||
        Map.get(map, "replacement") ||
        Map.get(map, :replacement_content) ||
        Map.get(map, "replacement_content") ||
        ""

    tier =
      case Map.get(map, :tier) || Map.get(map, "tier") do
        :ast -> :ast
        "ast" -> :ast
        :exact -> :exact
        "exact" -> :exact
        :fuzzy -> :fuzzy
        "fuzzy" -> :fuzzy
        _ -> :auto
      end

    allow_multiple =
      Map.get(map, :allow_multiple, false) == true or
        Map.get(map, "allow_multiple", false) == true

    %{
      path: path,
      target: target,
      replacement: replacement,
      tier: tier,
      allow_multiple: allow_multiple
    }
  end

  defp resolve_file_path(project_root, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(Path.join(project_root, path))
    end
  end
end
