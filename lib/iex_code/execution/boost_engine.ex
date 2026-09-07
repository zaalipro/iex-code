defmodule IexCode.Execution.BoostEngine do
  @moduledoc """
  3-Tier Deep Reasoning & Codebase Context Boost Engine.

  Elevates standard agent runs and swarm goals into a high-difficulty engineering
  pipeline inspired by modern multi-agent coding harnesses:
  1. Primary Orchestrator (Strategy, dependency mapping, contract enforcement)
  2. DeepCoder (High-reasoning, AST-aligned surgical code generation)
  3. DeepInvestigator & Test Verifier (Adversarial edge-case audit & automated self-correction loop)

  Augments the execution context with:
  - Project AST symbols matching key objective terms
  - Git working tree diff and status
  - Maximized reasoning effort ("high") and extended thinking token budget (16k)
  """

  alias IexCode.Tools.{ASTSearch, Git}

  @hierarchy [
    %{
      tier: 1,
      id: "orchestrator",
      title: "Primary Orchestrator",
      role: "Strategic decomposition, architectural contract enforcement, and handoffs",
      reasoning_effort: "high"
    },
    %{
      tier: 2,
      id: "deep_coder",
      title: "DeepCoder",
      role: "AST-aligned code synthesis, modular refactoring, and sound implementation",
      reasoning_effort: "high"
    },
    %{
      tier: 3,
      id: "verifier",
      title: "DeepInvestigator & Verifier",
      role: "Adversarial boundary probing, ExUnit test execution, and self-correction loop",
      reasoning_effort: "high"
    }
  ]

  @doc "Returns the 3-tier reasoning hierarchy specifications."
  def hierarchy, do: @hierarchy

  @doc """
  Enriches the objective with codebase context (AST symbols, git diff, project structure).
  """
  def boost_context(objective, project_path, _opts \\ []) do
    clean_obj = String.trim(to_string(objective || ""))
    symbols = extract_relevant_symbols(clean_obj, project_path)
    git_summary = extract_git_summary(project_path)

    prompt_enhancement = build_boost_prompt_block(clean_obj, symbols, git_summary)

    %{
      objective: clean_obj,
      symbols: symbols,
      git_summary: git_summary,
      prompt_enhancement: prompt_enhancement
    }
  end

  @doc """
  Elevates an execution policy map with Boost mode parameters:
  - reasoning_effort: "high"
  - thinking_budget: 16_384
  - max_tokens & max_completion_tokens: >= 16_384 (preventing reasoning starvation)
  - agent_max_turns: 20
  - boost: true
  - boost_tier: "deep_reasoning_v1"
  """
  def boost_policy(policy, caps \\ nil)

  def boost_policy(policy, _caps) when is_map(policy) do
    # Elevate policy with Boost parameters, respecting existing key type (string vs atom)
    atom_keys? =
      Enum.any?(Map.keys(policy), &is_atom/1) and not Enum.any?(Map.keys(policy), &is_binary/1)

    if atom_keys? do
      policy
      |> Map.put(:boost, true)
      |> Map.put(:boost_tier, "deep_reasoning_v1")
      |> Map.put(:boost_hierarchy, ["orchestrator", "deep_coder", "verifier"])
      |> Map.put(:reasoning_effort, "high")
      |> Map.put(:thinking_budget, 16_384)
      |> Map.update(:max_tokens, 16_384, &max(&1, 16_384))
      |> Map.update(:max_completion_tokens, 16_384, &max(&1, 16_384))
      |> Map.update(:agent_max_turns, 20, &max(&1, 20))
      |> Map.update(:swarm_agent_count, 5, &max(&1, 5))
    else
      policy
      |> Map.put("boost", true)
      |> Map.put("boost_tier", "deep_reasoning_v1")
      |> Map.put("boost_hierarchy", ["orchestrator", "deep_coder", "verifier"])
      |> Map.put("reasoning_effort", "high")
      |> Map.put("thinking_budget", 16_384)
      |> Map.update("max_tokens", 16_384, &max(&1, 16_384))
      |> Map.update("max_completion_tokens", 16_384, &max(&1, 16_384))
      |> Map.update("agent_max_turns", 20, &max(&1, 20))
      |> Map.update("swarm_agent_count", 5, &max(&1, 5))
    end
  end

  def boost_policy(other, _caps), do: other

  @doc "Converts a boost context map into a JSON-serializable map."
  def to_map(%{symbols: symbols, git_summary: git_summary, prompt_enhancement: pe}) do
    %{
      "symbols" => symbols,
      "git_summary" => git_summary,
      "prompt_enhancement" => pe
    }
  end

  def to_map(%{"symbols" => _, "git_summary" => _, "prompt_enhancement" => _} = map), do: map
  def to_map(map) when is_map(map), do: map
  def to_map(nil), do: nil

  @doc """
  Constructs the effective execution prompt for an agent or swarm run by
  incorporating active Boost prompt enhancements (3-tier hierarchy, AST symbols,
  Git status) and Teamwork Blueprint milestones if present in run metadata.
  """
  def effective_prompt(run) do
    base =
      cond do
        is_binary(run) ->
          run

        is_map(run) ->
          Map.get(run, :objective) || Map.get(run, "objective") || ""

        true ->
          ""
      end

    metadata =
      cond do
        is_map(run) and is_map(Map.get(run, :metadata)) ->
          Map.get(run, :metadata)

        is_map(run) and is_map(Map.get(run, "metadata")) ->
          Map.get(run, "metadata")

        true ->
          %{}
      end

    prompt_enhancement =
      Map.get(metadata, "prompt_enhancement") || Map.get(metadata, :prompt_enhancement)

    blueprint_raw =
      Map.get(metadata, "teamwork_blueprint") || Map.get(metadata, :teamwork_blueprint)

    blueprint_cli =
      case blueprint_raw do
        %IexCode.Execution.Teamwork.Blueprint{} = bp ->
          "\n\n" <> IexCode.Execution.Teamwork.format_cli(bp)

        %{} = map ->
          case IexCode.Execution.Teamwork.from_map(map) do
            %IexCode.Execution.Teamwork.Blueprint{} = bp ->
              "\n\n" <> IexCode.Execution.Teamwork.format_cli(bp)

            _ ->
              ""
          end

        _ ->
          ""
      end

    cond do
      is_binary(prompt_enhancement) and prompt_enhancement != "" and blueprint_cli != "" ->
        base <> "\n\n" <> prompt_enhancement <> blueprint_cli

      is_binary(prompt_enhancement) and prompt_enhancement != "" ->
        base <> "\n\n" <> prompt_enhancement

      blueprint_cli != "" ->
        base <> blueprint_cli

      true ->
        base
    end
  end

  # --- Internal Context Gathering ---

  defp extract_relevant_symbols(objective, project_path) when is_binary(project_path) do
    stop_words = ~w(
      the and for with that this from have been were will would could should lets does
      what when where which some further next also into over under than then them they
      here there each every both few more most other only same such than too very
      objective improvements verifications fixes lets make take build get set show
      run task goal preview swarm agent boost level app
    )

    tokens =
      objective
      |> String.split(~r/[^\w]+/, trim: true)
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 in stop_words))
      |> Enum.take(8)

    target_path =
      if File.dir?(Path.join(project_path, "lib")), do: "lib", else: ""

    symbol_candidates =
      try do
        Enum.flat_map(tokens, fn token ->
          query =
            if target_path != "", do: %{name: token, path: target_path}, else: %{name: token}

          case ASTSearch.search(project_path, query, limit: 5) do
            {:ok, list} ->
              Enum.map(list, fn sym ->
                %{
                  name: sym.name,
                  kind: sym.type,
                  file: sym.file,
                  line: sym.line
                }
              end)

            _ ->
              []
          end
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    git_symbols =
      if length(symbol_candidates) < 5 do
        try do
          case Git.status(project_path) do
            {:ok, %{staged: staged, unstaged: unstaged}} ->
              modified_files =
                (staged ++ unstaged)
                |> Enum.reject(&String.starts_with?(&1, "tmp/"))
                |> Enum.take(3)

              Enum.flat_map(modified_files, fn file ->
                case ASTSearch.search(project_path, %{file: file}, limit: 3) do
                  {:ok, list} ->
                    Enum.map(list, fn sym ->
                      %{
                        name: sym.name,
                        kind: sym.type,
                        file: sym.file,
                        line: sym.line
                      }
                    end)

                  _ ->
                    []
                end
              end)

            _ ->
              []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      else
        []
      end

    (symbol_candidates ++ git_symbols)
    |> Enum.uniq_by(&{&1.name, &1.file, &1.line})
    |> Enum.take(12)
  end

  defp extract_relevant_symbols(_objective, _path), do: []

  defp extract_git_summary(project_path) when is_binary(project_path) do
    try do
      case Git.status(project_path) do
        {:ok, %{staged: staged, unstaged: unstaged, untracked: untracked} = stat} ->
          changes_count = length(staged) + length(unstaged) + length(untracked)
          branch_str = if Map.get(stat, :branch), do: " [branch: #{stat.branch}]", else: ""

          "Git working tree#{branch_str}: #{changes_count} active changes (#{length(staged)} staged, #{length(unstaged)} unstaged, #{length(untracked)} untracked)"

        _ ->
          "Git status: clean or unavailable"
      end
    rescue
      _ -> "Git status: clean"
    catch
      :exit, _ -> "Git status: clean"
    end
  end

  defp extract_git_summary(_path), do: "Git status: clean"

  defp build_boost_prompt_block(_objective, symbols, git_summary) do
    symbols_text =
      if symbols != [] do
        symbols_lines =
          Enum.map_join(symbols, "\n", fn s ->
            "  • #{s.kind} #{s.name} (#{s.file}:#{s.line})"
          end)

        """
        [Active Architectural Symbols]:
        #{symbols_lines}
        """
      else
        ""
      end

    """
    ⚡ BOOST MODE ENGAGED [3-TIER REASONING HIERARCHY ACTIVE]
    Tier 1 (Sentinel Orchestrator): Enforces atomic milestone decomposition and architectural invariance.
    Tier 2 (DeepCoder): AST-aligned surgical implementation with zero unsolicited refactors.
    Tier 3 (DeepInvestigator & Verifier): Exhaustive adversarial edge-case testing, property verification, and self-correction loop.

    [Working Tree Context]:
    #{git_summary}
    #{symbols_text}
    [Engineering Mandate]:
    - Solve the general problem soundly without special-casing test inputs.
    - Never weaken or delete existing tests; all suites must pass 100%.
    - Comply strictly with Phoenix/LiveView/OTP conventions.
    """
  end
end
