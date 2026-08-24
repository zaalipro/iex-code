defmodule IexCode.Tools do
  @moduledoc """
  Core tool execution engine for agents in IexCode.
  All tools are executed safely in the context of the active workspace project.
  """
  require Logger

  alias IexCode.Research.{Fetcher, Search}
  alias IexCode.Settings
  alias IexCode.Tools.{ASTSearch, Git, MultiPatch, TerminalServer, TestRunner}
  alias IexCode.WorkspacePath

  @max_command_output 256_000
  @excluded_dirs ["_build", "deps", "node_modules", ".git"]

  @doc """
  Returns tool specifications formatted for Anthropic and OpenAI tool calls.
  """
  def tool_definitions(allowlist \\ :all) do
    definitions = [
      %{
        name: "read_file",
        description: "Read contents of a file from the workspace filesystem.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Relative or absolute path to the file"},
            start_line: %{type: "integer", description: "Optional 1-indexed start line"},
            end_line: %{type: "integer", description: "Optional 1-indexed end line"}
          },
          required: ["path"]
        }
      },
      %{
        name: "write_file",
        description: "Write or create a file in the workspace.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to write"},
            content: %{type: "string", description: "Complete content to write"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "patch_file",
        description: "Replace exact target content inside a file with replacement content.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to modify"},
            target_content: %{type: "string", description: "Exact string in the file to replace"},
            replacement_content: %{type: "string", description: "Replacement content string"}
          },
          required: ["path", "target_content", "replacement_content"]
        }
      },
      %{
        name: "multi_patch",
        description:
          "Atomically apply multiple code patches across one or more files with 3-tier matching (AST, exact, fuzzy) and automatic rollback on failure.",
        parameters: %{
          type: "object",
          properties: %{
            patches: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  path: %{type: "string", description: "Relative file path"},
                  target_content: %{type: "string", description: "Target code to replace"},
                  replacement_content: %{type: "string", description: "Replacement code"}
                },
                required: ["path", "target_content", "replacement_content"]
              },
              description: "List of patch objects to apply atomically"
            }
          },
          required: ["patches"]
        }
      },
      %{
        name: "ast_search",
        description:
          "Search Elixir AST symbols (modules, functions, specs, docs, attributes) across workspace.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Symbol name or search string"},
            type: %{
              type: "string",
              enum: [
                "all",
                "module",
                "function",
                "macro",
                "spec",
                "doc",
                "attribute",
                "type",
                "callback"
              ],
              description: "Symbol type filter"
            },
            path: %{type: "string", description: "Optional subpath to search within"},
            arity: %{type: "integer", description: "Optional function arity filter"},
            line: %{type: "integer", description: "Optional target line number"}
          },
          required: ["query"]
        }
      },
      %{
        name: "run_tests",
        description:
          "Run mix test suite or specific test file with structured failure diagnostics.",
        parameters: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional test files or paths to run"
            },
            line: %{
              type: "integer",
              description: "Optional line number when running a single test file"
            },
            failed: %{type: "boolean", description: "Run only previously failed tests"},
            seed: %{type: "integer", description: "Seed for test execution"},
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds (default 60000)"}
          }
        }
      },
      %{
        name: "git_status",
        description: "Get structured Git status (branch, staged, unstaged, untracked files).",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Optional repo directory path"}
          }
        }
      },
      %{
        name: "git_diff",
        description: "Get Git diff of working tree or staged changes.",
        parameters: %{
          type: "object",
          properties: %{
            staged: %{type: "boolean", description: "Whether to return staged diff (--cached)"},
            paths: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional paths filter"
            }
          }
        }
      },
      %{
        name: "git_stage",
        description: "Stage files for Git commit.",
        parameters: %{
          type: "object",
          properties: %{
            files: %{
              type: "array",
              items: %{type: "string"},
              description: "List of file paths to stage (or '.' for all)"
            }
          },
          required: ["files"]
        }
      },
      %{
        name: "git_commit",
        description: "Commit staged changes with a commit message.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Commit message"},
            allow_empty: %{type: "boolean", description: "Allow empty commit"}
          },
          required: ["message"]
        }
      },
      %{
        name: "git_generate_commit",
        description: "Generate a conventional semantic commit message from staged changes.",
        parameters: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "list_dir",
        description: "List directory contents including files and subdirectories.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Directory path relative to workspace or absolute"
            },
            recursive: %{type: "boolean", description: "Whether to list recursively"}
          }
        }
      },
      %{
        name: "grep_search",
        description: "Search for regex or text query patterns across project files.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Text or regex pattern to search for"},
            path: %{type: "string", description: "Subdirectory or file to search in"},
            case_sensitive: %{type: "boolean", description: "Whether search is case-sensitive"}
          },
          required: ["query"]
        }
      },
      %{
        name: "run_command",
        description: "Execute a terminal / shell command in the project directory.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "Shell command line to execute"},
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds (default 30000)"}
          },
          required: ["command"]
        }
      },
      %{
        name: "web_search",
        description:
          "Federated public web search with normalized titles, URLs, snippets, providers, and citation-ready source identifiers.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"},
            providers: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Optional configured providers (Tavily, Brave, Exa, Serper, Google, Bing, SearxNG, DuckDuckGo)"
            },
            max_results: %{
              type: "integer",
              description: "Maximum normalized results to return (1-50)"
            }
          },
          required: ["query"]
        }
      },
      %{
        name: "fetch_url",
        description:
          "Fetch readable text from a public HTTP(S) source with DNS, redirect, MIME, timeout, and response-size safety checks.",
        parameters: %{
          type: "object",
          properties: %{
            url: %{type: "string", description: "Public HTTP(S) URL to fetch"}
          },
          required: ["url"]
        }
      }
    ]

    filter_tool_definitions(definitions, allowlist)
  end

  # --- Direct Delegations ---
  def ast_search(query, root_path \\ "."), do: ASTSearch.search(root_path, query)
  def multi_patch(patches, root_path \\ "."), do: MultiPatch.apply_patches(root_path, patches)
  def run_tests(opts \\ []), do: TestRunner.run(opts)
  def git_status(repo_dir \\ "."), do: Git.status(repo_dir)
  def git_diff(repo_dir \\ ".", opts \\ []), do: Git.diff(repo_dir, opts)
  def git_stage(files, repo_dir \\ "."), do: Git.stage(files, repo_dir)
  def git_commit(message, repo_dir \\ "."), do: Git.commit(message, repo_dir)
  def git_generate_commit(repo_dir \\ "."), do: Git.generate_commit_message(repo_dir)

  @doc """
  Executes a named tool with arguments inside the workspace `root_path`.
  Implementation crashes are contained and returned as `{:error, reason}`
  instead of propagating to callers.
  """
  def execute(tool_name, args, root_path, on_progress \\ fn _p, _msg -> :ok end) do
    do_execute(tool_name, args, root_path, on_progress)
  rescue
    exception -> {:error, "Tool #{tool_name} crashed: #{Exception.message(exception)}"}
  end

  defp do_execute("read_file", %{"path" => path} = args, root_path, on_progress) do
    on_progress.(10, "Resolving path: #{path}")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.exists?(full_path) do
          on_progress.(50, "Reading file bytes...")

          case File.read(full_path) do
            {:ok, content} ->
              lines = String.split(content, ~r/\r?\n/)
              start_l = Map.get(args, "start_line")
              end_l = Map.get(args, "end_line")

              sliced_lines =
                cond do
                  is_integer(start_l) and is_integer(end_l) and start_l <= end_l ->
                    Enum.slice(lines, max(0, start_l - 1), max(1, end_l - start_l + 1))

                  is_integer(start_l) ->
                    Enum.slice(lines, max(0, start_l - 1)..-1//1)

                  true ->
                    capped = Enum.take(lines, 800)

                    if length(lines) > 800 do
                      capped ++
                        [
                          "... [truncated: showing 800 of #{length(lines)} lines, use start_line/end_line for more]"
                        ]
                    else
                      capped
                    end
                end

              numbered =
                sliced_lines
                |> Enum.with_index(if is_integer(start_l), do: start_l, else: 1)
                |> Enum.map(fn {line, idx} -> "#{idx}: #{line}" end)
                |> Enum.join("\n")

              on_progress.(100, "Read complete (#{length(sliced_lines)} lines)")
              {:ok, IexCode.Sessions.sanitize_utf8(numbered)}

            {:error, reason} ->
              {:error, "Failed to read file #{path}: #{inspect(reason)}"}
          end
        else
          {:error, "File does not exist: #{path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute("write_file", %{"path" => path, "content" => content}, root_path, on_progress) do
    on_progress.(20, "Creating parent directories for #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        File.mkdir_p!(Path.dirname(full_path))

        on_progress.(70, "Writing #{byte_size(content)} bytes to file...")

        case atomic_write(full_path, content) do
          :ok ->
            on_progress.(100, "File written successfully: #{path}")
            {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

          {:error, reason} ->
            {:error, "Failed to write file #{path}: #{inspect(reason)}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute(
         "patch_file",
         %{"path" => path, "target_content" => target, "replacement_content" => replacement},
         root_path,
         on_progress
       ) do
    on_progress.(20, "Reading target file #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.exists?(full_path) do
          content = File.read!(full_path)

          case MultiPatch.patch_string(content, target, replacement) do
            {:ok, %{content: new_content}} ->
              on_progress.(60, "Replacing target content...")

              case atomic_write(full_path, new_content) do
                :ok ->
                  on_progress.(100, "Patched #{path} successfully")
                  {:ok, "Successfully patched #{path}"}

                {:error, reason} ->
                  {:error, "Failed to write patched file #{path}: #{inspect(reason)}"}
              end

            {:error, :not_found} ->
              {:error, "Target content not found in #{path}"}
          end
        else
          {:error, "File does not exist: #{path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{path}"}
    end
  end

  defp do_execute("multi_patch", %{"patches" => patches} = args, root_path, on_progress) do
    on_progress.(20, "Applying #{length(patches)} patches atomically...")

    case MultiPatch.apply_patches(root_path, patches,
           session_id: Map.get(args, "session_id"),
           run_id: Map.get(args, "run_id")
         ) do
      {:ok, summary} ->
        on_progress.(100, "Applied #{summary.applied} patches successfully")

        msg =
          "Applied #{summary.applied} patches (AST: #{summary.tiers_used.ast}, Exact: #{summary.tiers_used.exact}, Fuzzy: #{summary.tiers_used.fuzzy}).\n\n#{summary.diff}"

        {:ok, msg}

      {:error, reason} ->
        {:error, "MultiPatch failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("ast_search", args, root_path, on_progress) do
    on_progress.(30, "Scanning AST symbols in #{root_path}...")

    case ASTSearch.search(root_path, args) do
      {:ok, results} ->
        on_progress.(100, "Found #{length(results)} matching symbols")
        formatted = ASTSearch.format_results(results, include_code: true)
        {:ok, formatted}

      {:error, reason} ->
        {:error, "AST search failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("run_tests", args, root_path, on_progress) do
    opts =
      [project_root: root_path, on_progress: on_progress]
      |> add_opt_from_map(args, "paths", :paths)
      |> add_opt_from_map(args, "line", :line)
      |> add_opt_from_map(args, "failed", :failed)
      |> add_opt_from_map(args, "seed", :seed)
      |> add_opt_from_map(args, "timeout_ms", :timeout_ms)

    case TestRunner.run(opts) do
      {:ok, %{status: :passed} = res} ->
        {:ok, "Tests PASSED: #{res.total} tests (#{res.duration_s}s)"}

      {:ok, %{status: :failed} = res} ->
        failures_summary =
          res.failures
          |> Enum.map(fn f ->
            code_line = if f.code_snippet, do: "\n    code: #{f.code_snippet}", else: ""
            "  * #{f.file}:#{f.line} - #{f.test_name} (#{f.module})\n    #{f.message}#{code_line}"
          end)
          |> Enum.join("\n")

        {:ok,
         "Tests FAILED: #{res.failures_count}/#{res.total} failures:\n#{failures_summary}\n\nRaw output:\n#{res.raw_output}"}

      {:ok, %{status: :compilation_error} = res} ->
        errs =
          res.compilation_errors
          |> Enum.map(fn e -> "  * #{e.file}:#{e.line} [#{e.error_type}] #{e.message}" end)
          |> Enum.join("\n")

        {:error, "Compilation errors before test run:\n#{errs}"}

      {:ok, %{status: status} = res} ->
        {:ok, "Tests completed with status #{status}:\n#{res.raw_output}"}

      {:error, reason} ->
        {:error, "Test run failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_status", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""

    case resolve_path(root_path, sub_path) do
      {:ok, repo_dir} ->
        on_progress.(30, "Checking git status for #{repo_dir}...")

        case Git.status(repo_dir) do
          {:ok, status_res} ->
            on_progress.(100, "Git status retrieved")

            staged_list =
              Enum.map_join(status_res.staged, "\n  ", fn s -> "#{s.status}: #{s.path}" end)

            unstaged_list =
              Enum.map_join(status_res.unstaged, "\n  ", fn s -> "#{s.status}: #{s.path}" end)

            untracked_list = Enum.map_join(status_res.untracked, "\n  ", & &1)

            msg =
              """
              Branch: #{status_res.branch} (clean: #{status_res.clean?})
              Staged (#{length(status_res.staged)}):
                #{if staged_list == "", do: "(none)", else: staged_list}
              Unstaged (#{length(status_res.unstaged)}):
                #{if unstaged_list == "", do: "(none)", else: unstaged_list}
              Untracked (#{length(status_res.untracked)}):
                #{if untracked_list == "", do: "(none)", else: untracked_list}
              """
              |> String.trim()

            {:ok, msg}

          {:error, reason} ->
            {:error, "Git status failed: #{inspect(reason)}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("git_diff", args, root_path, on_progress) do
    staged? = Map.get(args, "staged", false) == true
    paths = Map.get(args, "paths", [])
    on_progress.(30, "Fetching diff (staged: #{staged?})...")

    case Git.diff(root_path, staged: staged?, paths: paths) do
      {:ok, diff_text} ->
        on_progress.(100, "Diff fetched (#{byte_size(diff_text)} bytes)")
        {:ok, if(diff_text == "", do: "(No changes)", else: diff_text)}

      {:error, reason} ->
        {:error, "Git diff failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_stage", %{"files" => files}, root_path, on_progress) do
    on_progress.(30, "Staging files: #{inspect(files)}...")

    case Git.stage(files, root_path) do
      :ok ->
        on_progress.(100, "Staged files successfully")
        {:ok, "Staged #{inspect(files)} successfully"}

      {:error, reason} ->
        {:error, "Git stage failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_commit", %{"message" => message} = args, root_path, on_progress) do
    allow_empty = Map.get(args, "allow_empty", false) == true
    on_progress.(30, "Creating commit with message: #{message}...")

    case Git.commit(message, root_path, allow_empty: allow_empty) do
      {:ok, commit_res} ->
        on_progress.(100, "Created commit #{commit_res.short_hash}")
        {:ok, "Created commit #{commit_res.short_hash}: #{commit_res.message}"}

      {:error, :nothing_staged} ->
        {:error, "Nothing staged to commit (use allow_empty: true if intentional)"}

      {:error, reason} ->
        {:error, "Git commit failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("git_generate_commit", _args, root_path, on_progress) do
    on_progress.(30, "Analyzing changes to generate semantic commit...")

    case Git.generate_commit_message(root_path) do
      {:ok, msg} ->
        on_progress.(100, "Generated commit message")
        {:ok, msg}

      {:error, reason} ->
        {:error, "Git generate commit failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("list_dir", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    on_progress.(30, "Listing #{sub_path}...")

    case resolve_path(root_path, sub_path) do
      {:ok, full_path} ->
        if File.dir?(full_path) do
          recursive? = Map.get(args, "recursive", false) == true

          entries =
            if recursive? do
              Path.wildcard(Path.join(full_path, "**/*"))
              |> Enum.reject(fn p ->
                p
                |> Path.relative_to(full_path)
                |> Path.split()
                |> List.first()
                |> excluded_dir?()
              end)
              |> Enum.take(200)
              |> Enum.map(fn p ->
                rel = Path.relative_to(p, full_path)
                {type, size} = entry_type_and_size(p)
                "#{type}\t#{size}\t#{rel}"
              end)
            else
              File.ls!(full_path)
              |> Enum.reject(&excluded_dir?/1)
              |> Enum.take(150)
              |> Enum.map(fn item ->
                p = Path.join(full_path, item)
                {type, size} = entry_type_and_size(p)
                "#{type}\t#{size}\t#{item}"
              end)
            end

          on_progress.(100, "Listed #{length(entries)} items")
          {:ok, Enum.join(entries, "\n")}
        else
          {:error, "Not a directory: #{sub_path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("grep_search", %{"query" => query} = args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    case_sensitive? = Map.get(args, "case_sensitive", false)

    case resolve_path(root_path, sub_path) do
      {:ok, search_dir} ->
        on_progress.(30, "Scanning files in #{search_dir} for query '#{query}'...")

        matcher = build_matcher(query, case_sensitive?)

        results =
          Path.wildcard(Path.join(search_dir, "**/*"))
          |> Enum.reject(fn p ->
            ext = Path.extname(p) |> String.downcase()

            File.dir?(p) or
              ext in [
                ".db",
                ".db-wal",
                ".db-shm",
                ".beam",
                ".png",
                ".jpg",
                ".jpeg",
                ".ico",
                ".svg",
                ".lock",
                ".dump",
                ".gz",
                ".zip"
              ] or
              String.contains?(p, "/_build/") or
              String.contains?(p, "/deps/") or
              String.contains?(p, "/.git/") or
              String.contains?(p, "/node_modules/")
          end)
          |> Enum.take(500)
          |> Enum.flat_map(fn file_path ->
            case File.read(file_path) do
              {:ok, content} ->
                if String.valid?(content) do
                  rel = Path.relative_to(file_path, root_path)

                  content
                  |> String.split("\n")
                  |> Enum.with_index(1)
                  |> Enum.filter(fn {line, _idx} ->
                    line_matches?(line, matcher, case_sensitive?)
                  end)
                  |> Enum.take(10)
                  |> Enum.map(fn {line, idx} -> "#{rel}:#{idx}: #{String.trim(line)}" end)
                else
                  []
                end

              # Explicitly skip unreadable files (permissions, broken symlinks, races).
              {:error, _reason} ->
                []
            end
          end)
          |> Enum.take(100)

        on_progress.(100, "Found #{length(results)} matches")

        {:ok,
         if(results == [], do: "No matches found for '#{query}'", else: Enum.join(results, "\n"))}

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{sub_path}"}
    end
  end

  defp do_execute("run_command", args, root_path, on_progress) do
    command = Map.get(args, "command") || Map.get(args, :command)
    session_id = Map.get(args, "session_id") || Map.get(args, :session_id)
    timeout = Map.get(args, "timeout_ms") || Map.get(args, :timeout_ms) || 30_000
    agent_name = Map.get(args, "agent_name") || Map.get(args, :agent_name) || "Agent"
    op_id = Map.get(args, "op_id") || Map.get(args, :op_id)

    if session_id && session_id != "" do
      on_progress.(20, "Executing agent command in terminal: #{command}")

      case TerminalServer.run_agent_command(session_id, command, agent_name,
             timeout_ms: timeout,
             op_id: op_id,
             workspace_path: root_path
           ) do
        {:ok, %{exit_code: 0, output: output}} ->
          on_progress.(100, "Command exited successfully (0)")
          {:ok, output}

        {:ok, %{exit_code: exit_code, output: output}} ->
          on_progress.(100, "Command failed (code #{exit_code})")
          {:ok, "Exit Code #{exit_code}:\n#{output}"}

        {:error, :timeout} ->
          on_progress.(100, "Command timed out after #{timeout}ms")
          {:error, "Command timed out after #{timeout}ms"}

        {:error, reason} ->
          on_progress.(100, "Command failed: #{inspect(reason)}")
          {:error, "Command failed: #{inspect(reason)}"}
      end
    else
      on_progress.(20, "Starting command: #{command} in #{root_path}")

      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-c", command],
            cd: root_path
          ]
        )

      deadline = System.monotonic_time(:millisecond) + timeout

      case collect_port_output(port, deadline, {"", false}) do
        {:done, exit_code, {output, truncated?}} ->
          suffix =
            if truncated? do
              "\n\n[output truncated at #{@max_command_output} bytes]"
            else
              ""
            end

          output = IexCode.Sessions.sanitize_utf8(output) <> suffix

          if exit_code == 0 do
            on_progress.(100, "Command exited successfully (0)")
            {:ok, output}
          else
            on_progress.(100, "Command failed (code #{exit_code})")
            {:ok, "Exit Code #{exit_code}:\n#{output}"}
          end

        {:timeout, {output, truncated?}} ->
          # Closing the port terminates the connected /bin/sh. Best-effort only:
          # orphaned grandchildren spawned by the command may survive since we do
          # not track the full OS process tree.
          Port.close(port)
          on_progress.(100, "Command timed out after #{timeout}ms")

          suffix =
            if truncated? do
              "\n\n[output truncated at #{@max_command_output} bytes]"
            else
              ""
            end

          {:error,
           "Command timed out after #{timeout}ms. Partial output:\n#{IexCode.Sessions.sanitize_utf8(output)}#{suffix}"}
      end
    end
  end

  defp do_execute("web_search", %{"query" => query} = args, _root_path, on_progress) do
    search_config = Settings.search_config()
    requested_providers = Map.get(args, "providers")

    providers =
      if requested_providers in [nil, []], do: search_config.order, else: requested_providers

    max_results = args |> Map.get("max_results", 10) |> normalize_search_limit()

    on_progress.(15, "Searching #{Enum.join(providers, ", ")}...")

    case Search.search(query,
           providers: providers,
           config: search_config,
           limit: max_results,
           max_concurrency: search_config.parallelism
         ) do
      {:ok, response} ->
        results = Enum.take(response.results, max_results)

        on_progress.(
          100,
          "Found #{length(results)} sources across #{length(response.providers)} providers"
        )

        {:ok, format_search_results(query, results, response.errors)}

      {:error, reason} ->
        {:error, "Federated search failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("fetch_url", %{"url" => url}, _root_path, on_progress) do
    on_progress.(15, "Validating public source URL...")

    case Fetcher.fetch(url) do
      {:ok, fetched} ->
        on_progress.(100, "Fetched #{fetched.bytes} bounded bytes")
        {:ok, "Source: #{fetched.url}\nContent-Type: #{fetched.content_type}\n\n#{fetched.text}"}

      {:error, reason} ->
        {:error, "Public source fetch rejected: #{inspect(reason)}"}
    end
  end

  defp do_execute(unknown_tool, _args, _root_path, _on_progress) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp resolve_path(root_path, path) do
    case WorkspacePath.resolve(root_path, path) do
      {:ok, full_path} -> {:ok, full_path}
      {:error, _reason} -> {:error, :outside_workspace}
    end
  end

  defp excluded_dir?(name) when name in @excluded_dirs, do: true
  defp excluded_dir?(_name), do: false

  defp entry_type_and_size(path) do
    if File.dir?(path) do
      {"dir", "-"}
    else
      case File.stat(path) do
        {:ok, stat} -> {"file", "#{stat.size}B"}
        # Unreadable file or broken symlink — report without crashing.
        {:error, _reason} -> {"file", "?"}
      end
    end
  end

  defp build_matcher(query, case_sensitive?) do
    case Regex.compile(query, if(case_sensitive?, do: "", else: "i")) do
      {:ok, regex} ->
        {:regex, regex}

      {:error, _invalid} ->
        needle = if case_sensitive?, do: query, else: String.downcase(query)
        {:text, needle}
    end
  end

  defp line_matches?(line, {:regex, regex}, _case_sensitive?), do: Regex.match?(regex, line)

  defp line_matches?(line, {:text, needle}, case_sensitive?) do
    if case_sensitive? do
      String.contains?(line, needle)
    else
      String.contains?(String.downcase(line), needle)
    end
  end

  # Writes content to a temp file next to the target, then renames it into
  # place so readers never observe a partially-written file.
  defp atomic_write(full_path, content) do
    tmp_path = "#{full_path}.tmp#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, full_path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp collect_port_output(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, acc}
    else
      receive do
        {^port, {:data, data}} ->
          collect_port_output(port, deadline, append_capped(acc, data))

        {^port, {:exit_status, status}} ->
          {:done, status, drain_port(port, acc)}
      after
        remaining -> {:timeout, acc}
      end
    end
  end

  # Data can still be buffered after the exit status arrives; drain it
  # without blocking.
  defp drain_port(port, acc) do
    receive do
      {^port, {:data, data}} -> drain_port(port, append_capped(acc, data))
    after
      0 -> acc
    end
  end

  defp append_capped({acc, truncated?}, data) do
    cond do
      truncated? ->
        {acc, true}

      byte_size(acc) + byte_size(data) <= @max_command_output ->
        {acc <> data, false}

      true ->
        take = max(@max_command_output - byte_size(acc), 0)
        {acc <> binary_part(data, 0, take), true}
    end
  end

  defp filter_tool_definitions(definitions, :all), do: definitions
  defp filter_tool_definitions(definitions, nil), do: definitions

  defp filter_tool_definitions(definitions, %MapSet{} = allowlist) do
    filter_tool_definitions(definitions, MapSet.to_list(allowlist))
  end

  defp filter_tool_definitions(definitions, allowlist) when is_list(allowlist) do
    allowed = MapSet.new(Enum.map(allowlist, &to_string/1))
    Enum.filter(definitions, &MapSet.member?(allowed, &1.name))
  end

  defp filter_tool_definitions(_definitions, _allowlist), do: []

  defp normalize_search_limit(value) when is_integer(value), do: value |> max(1) |> min(50)

  defp normalize_search_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_search_limit(parsed)
      _ -> 10
    end
  end

  defp normalize_search_limit(_value), do: 10

  defp format_search_results(query, results, errors) do
    sources =
      results
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {result, index} ->
        "[#{index}] #{result.title}\nURL: #{result.url}\nProvider: #{result.provider}\nSnippet: #{result.snippet || "(no snippet)"}"
      end)

    provider_notes =
      errors
      |> Enum.map_join("; ", fn {provider, reason} -> "#{provider}=#{inspect(reason)}" end)
      |> then(&if(&1 == "", do: "none", else: &1))

    "Federated search results for #{inspect(query)}\nProvider errors: #{provider_notes}\n\n#{sources}"
    |> IexCode.Sessions.sanitize_utf8()
  end

  defp add_opt_from_map(opts, map, map_key, opt_key) do
    case Map.get(map, map_key) do
      nil -> opts
      val -> Keyword.put(opts, opt_key, val)
    end
  end
end
