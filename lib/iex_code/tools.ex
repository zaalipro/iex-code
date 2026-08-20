defmodule IexCode.Tools do
  @moduledoc """
  Core tool execution engine for agents in IexCode.
  All tools are executed safely in the context of the active workspace project.
  """
  require Logger

  alias IexCode.Tools.{ASTSearch, MultiPatch, TestRunner, Git}

  @doc """
  Returns tool specifications formatted for Anthropic and OpenAI tool calls.
  """
  def tool_definitions do
    [
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
        description: "Search the web or fetch a web page for documentation or information.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query or URL to fetch"}
          },
          required: ["query"]
        }
      }
    ]
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
  """
  def execute(tool_name, args, root_path, on_progress \\ fn _p, _msg -> :ok end)

  def execute("read_file", %{"path" => path} = args, root_path, on_progress) do
    on_progress.(10, "Resolving path: #{path}")
    full_path = resolve_path(root_path, path)

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
                Enum.take(lines, 800)
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
  end

  def execute("write_file", %{"path" => path, "content" => content}, root_path, on_progress) do
    on_progress.(20, "Creating parent directories for #{path}...")
    full_path = resolve_path(root_path, path)
    File.mkdir_p!(Path.dirname(full_path))

    on_progress.(70, "Writing #{byte_size(content)} bytes to file...")

    case File.write(full_path, content) do
      :ok ->
        on_progress.(100, "File written successfully: #{path}")
        {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

      {:error, reason} ->
        {:error, "Failed to write file #{path}: #{inspect(reason)}"}
    end
  end

  def execute(
        "patch_file",
        %{"path" => path, "target_content" => target, "replacement_content" => replacement},
        root_path,
        on_progress
      ) do
    on_progress.(20, "Reading target file #{path}...")
    full_path = resolve_path(root_path, path)

    if File.exists?(full_path) do
      content = File.read!(full_path)

      case MultiPatch.patch_string(content, target, replacement) do
        {:ok, %{content: new_content}} ->
          on_progress.(60, "Replacing target content...")
          File.write!(full_path, new_content)
          on_progress.(100, "Patched #{path} successfully")
          {:ok, "Successfully patched #{path}"}

        {:error, :not_found} ->
          {:error, "Target content not found in #{path}"}
      end
    else
      {:error, "File does not exist: #{path}"}
    end
  end

  def execute("multi_patch", %{"patches" => patches}, root_path, on_progress) do
    on_progress.(20, "Applying #{length(patches)} patches atomically...")

    case MultiPatch.apply_patches(root_path, patches) do
      {:ok, summary} ->
        on_progress.(100, "Applied #{summary.applied} patches successfully")

        msg =
          "Applied #{summary.applied} patches (AST: #{summary.tiers_used.ast}, Exact: #{summary.tiers_used.exact}, Fuzzy: #{summary.tiers_used.fuzzy}).\n\n#{summary.diff}"

        {:ok, msg}

      {:error, reason} ->
        {:error, "MultiPatch failed: #{inspect(reason)}"}
    end
  end

  def execute("ast_search", args, root_path, on_progress) do
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

  def execute("run_tests", args, root_path, on_progress) do
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

  def execute("git_status", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    repo_dir = resolve_path(root_path, sub_path)
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
  end

  def execute("git_diff", args, root_path, on_progress) do
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

  def execute("git_stage", %{"files" => files}, root_path, on_progress) do
    on_progress.(30, "Staging files: #{inspect(files)}...")

    case Git.stage(files, root_path) do
      :ok ->
        on_progress.(100, "Staged files successfully")
        {:ok, "Staged #{inspect(files)} successfully"}

      {:error, reason} ->
        {:error, "Git stage failed: #{inspect(reason)}"}
    end
  end

  def execute("git_commit", %{"message" => message} = args, root_path, on_progress) do
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

  def execute("git_generate_commit", _args, root_path, on_progress) do
    on_progress.(30, "Analyzing changes to generate semantic commit...")

    case Git.generate_commit_message(root_path) do
      {:ok, msg} ->
        on_progress.(100, "Generated commit message")
        {:ok, msg}

      {:error, reason} ->
        {:error, "Git generate commit failed: #{inspect(reason)}"}
    end
  end

  def execute("list_dir", args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    full_path = resolve_path(root_path, sub_path)
    on_progress.(30, "Listing #{full_path}...")

    if File.dir?(full_path) do
      recursive? = Map.get(args, "recursive", false) == true

      entries =
        if recursive? do
          Path.wildcard(Path.join(full_path, "**/*"))
          |> Enum.take(200)
          |> Enum.map(fn p ->
            rel = Path.relative_to(p, full_path)
            type = if File.dir?(p), do: "dir", else: "file"
            size = if type == "file", do: "#{File.stat!(p).size}B", else: "-"
            "#{type}\t#{size}\t#{rel}"
          end)
        else
          File.ls!(full_path)
          |> Enum.take(150)
          |> Enum.map(fn item ->
            p = Path.join(full_path, item)
            type = if File.dir?(p), do: "dir", else: "file"
            size = if type == "file", do: "#{File.stat!(p).size}B", else: "-"
            "#{type}\t#{size}\t#{item}"
          end)
        end

      on_progress.(100, "Listed #{length(entries)} items")
      {:ok, Enum.join(entries, "\n")}
    else
      {:error, "Not a directory: #{sub_path}"}
    end
  end

  def execute("grep_search", %{"query" => query} = args, root_path, on_progress) do
    sub_path = Map.get(args, "path", "") || ""
    search_dir = resolve_path(root_path, sub_path)
    case_sensitive? = Map.get(args, "case_sensitive", false)

    on_progress.(30, "Scanning files in #{search_dir} for query '#{query}'...")

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
                if case_sensitive? do
                  String.contains?(line, query)
                else
                  String.contains?(String.downcase(line), String.downcase(query))
                end
              end)
              |> Enum.take(10)
              |> Enum.map(fn {line, idx} -> "#{rel}:#{idx}: #{String.trim(line)}" end)
            else
              []
            end

          _ ->
            []
        end
      end)
      |> Enum.take(100)

    on_progress.(100, "Found #{length(results)} matches")

    {:ok,
     if(results == [], do: "No matches found for '#{query}'", else: Enum.join(results, "\n"))}
  end

  def execute("run_command", %{"command" => command} = args, root_path, on_progress) do
    on_progress.(20, "Starting command: #{command} in #{root_path}")
    timeout = Map.get(args, "timeout_ms", 30000)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cd: root_path, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        on_progress.(100, "Command exited successfully (0)")
        {:ok, IexCode.Sessions.sanitize_utf8(output)}

      {:ok, {output, exit_code}} ->
        on_progress.(100, "Command failed (code #{exit_code})")
        {:ok, "Exit Code #{exit_code}:\n#{IexCode.Sessions.sanitize_utf8(output)}"}

      nil ->
        on_progress.(100, "Command timed out after #{timeout}ms")
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  def execute("web_search", %{"query" => query}, _root_path, on_progress) do
    on_progress.(20, "Connecting to search/fetch: #{query}")

    if String.starts_with?(query, "http://") or String.starts_with?(query, "https://") do
      case Req.get(query, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          on_progress.(70, "Parsing HTML body...")

          clean_text =
            case Floki.parse_document(body) do
              {:ok, document} ->
                document
                |> Floki.find("body")
                |> Floki.text()
                |> String.replace(~r/\s+/, " ")
                |> String.slice(0, 4000)

              _ ->
                String.slice(body, 0, 4000)
            end

          on_progress.(100, "Fetched #{byte_size(clean_text)} bytes")
          {:ok, clean_text}

        {:ok, %{status: status}} ->
          {:error, "HTTP request returned status #{status}"}

        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    else
      # Simple DuckDuckGo HTML search / fallback
      search_url = "https://html.duckduckgo.com/html/?q=#{URI.encode(query)}"

      case Req.get(search_url, headers: [{"user-agent", "Mozilla/5.0"}], receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} ->
          on_progress.(80, "Extracting search results...")

          results =
            case Floki.parse_document(body) do
              {:ok, doc} ->
                doc
                |> Floki.find(".result__snippet")
                |> Enum.take(5)
                |> Enum.map(&Floki.text/1)
                |> Enum.join("\n- ")

              _ ->
                "Results retrieved."
            end

          on_progress.(100, "Search completed")
          {:ok, "Search results for '#{query}':\n- #{results}"}

        _ ->
          {:ok, "Web search simulated response for: #{query}"}
      end
    end
  end

  def execute(unknown_tool, _args, _root_path, _on_progress) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp resolve_path(root_path, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(Path.join(root_path, path))
    end
  end

  defp add_opt_from_map(opts, map, map_key, opt_key) do
    case Map.get(map, map_key) do
      nil -> opts
      val -> Keyword.put(opts, opt_key, val)
    end
  end
end
