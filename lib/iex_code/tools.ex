defmodule IexCode.Tools do
  @moduledoc """
  Core tool execution engine for agents in IexCode.
  All tools are executed safely in the context of the active workspace project.
  """
  require Logger

  alias IexCode.{Projects, Runs}
  alias IexCode.Projects.Project
  alias IexCode.Research.{Fetcher, Search}
  alias IexCode.Sessions
  alias IexCode.Settings

  alias IexCode.Tools.{
    ASTSearch,
    Git,
    LSPClient,
    MultiPatch,
    ProcessGroupRunner,
    RepoMap,
    SymbolRefactor,
    TerminalServer,
    TestRunner
  }

  alias IexCode.Tools.MultiPatch.{Matcher, Snapshot}
  alias IexCode.WorkspacePath

  @max_command_output 256_000
  @excluded_dirs ["_build", "deps", "node_modules", ".git"]
  @diagnostics_excluded_dirs MapSet.new(["_build", "deps", "node_modules", ".git", "tmp"])

  @tool_aliases %{
    "view_file" => "read_file",
    "replace_file_content" => "patch_file",
    "write_to_file" => "write_file",
    "find_by_name" => "list_dir"
  }

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
            replacement_content: %{type: "string", description: "Replacement content string"},
            anchor_line: %{
              type: "integer",
              description: "Optional 1-based line hint used to disambiguate duplicate matches"
            },
            allow_multiple: %{
              type: "boolean",
              description:
                "Optional flag to replace all matching occurrences instead of failing on ambiguity"
            }
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
                  replacement_content: %{type: "string", description: "Replacement code"},
                  anchor_line: %{
                    type: "integer",
                    description:
                      "Optional 1-based line hint used to disambiguate duplicate matches"
                  },
                  allow_multiple: %{
                    type: "boolean",
                    description:
                      "Optional flag to replace all matching occurrences instead of failing on ambiguity"
                  }
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
        name: "semantic_code_search",
        description:
          "Perform hybrid BM25 + vector semantic search (or pure vector / lexical search) across the project codebase to retrieve relevant functions, modules, and code patterns.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Natural language or symbol query"},
            mode: %{
              type: "string",
              enum: ["hybrid", "vector", "lexical"],
              description:
                "Retrieval ranking mode: 'hybrid' (BM25 + dense vector RRF, default), 'vector' (dense cosine similarity), or 'lexical' (code-aware BM25 without embedding calls)"
            },
            limit: %{type: "integer", description: "Maximum results to return (default 10)"},
            threshold: %{
              type: "number",
              description: "Minimum similarity score 0.0-1.0 (default 0.4)"
            },
            path: %{type: "string", description: "Optional file path prefix filter"}
          },
          required: ["query"]
        }
      },
      %{
        name: "run_tests",
        description:
          "Run mix test suite, incremental changed-file tests, or specific test files with structured failure diagnostics.",
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
            changed: %{
              type: "boolean",
              description:
                "Select and run only tests affected by modified, staged, or untracked workspace files"
            },
            changed_files: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Optional explicit list of changed file paths used to select matching test files"
            },
            failed: %{type: "boolean", description: "Run only previously failed tests"},
            stale: %{
              type: "boolean",
              description: "Run only stale tests whose module dependencies changed (--stale)"
            },
            partition: %{
              type: "string",
              description:
                "Optional MIX_TEST_PARTITION suffix (e.g. 'auto' for an isolated ephemeral SQLite partition or '_agent1')"
            },
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
            timeout_ms: %{type: "integer", description: "Timeout in milliseconds (default 30000)"},
            sandbox_policy: %{
              type: "object",
              description:
                "Optional OS sandbox policy: reads/writes path prefixes, network allow|deny, strict bool"
            }
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
                "Optional configured ranked-search providers (Tavily, Brave, Exa, Perplexity, Firecrawl, Linkup, Serper, SerpApi, Google, Bing, SearxNG, DuckDuckGo)"
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
      },
      %{
        name: "update_plan",
        description: "Replace the run's task plan with an ordered list of steps and statuses.",
        parameters: %{
          type: "object",
          properties: %{
            steps: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  title: %{type: "string", description: "Short step title"},
                  status: %{
                    type: "string",
                    enum: ["pending", "in_progress", "done"],
                    description: "Step status (default pending)"
                  },
                  detail: %{type: "string", description: "Optional step detail"}
                },
                required: ["title"]
              },
              description: "Ordered plan steps"
            }
          },
          required: ["steps"]
        }
      },
      %{
        name: "request_input",
        description:
          "Pause the run and ask the user a question. Resume continues with the answer.",
        parameters: %{
          type: "object",
          properties: %{
            question: %{type: "string", description: "Question for the user"},
            options: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional suggested answers"
            }
          },
          required: ["question"]
        }
      },
      %{
        name: "spawn_agent",
        description:
          "Spawn a bounded child agent to complete an objective and report back a summary.",
        parameters: %{
          type: "object",
          properties: %{
            objective: %{type: "string", description: "Objective for the child agent"},
            max_turns: %{
              type: "integer",
              description: "Child turn budget 1-10 (default 5)"
            },
            mode: %{
              type: "string",
              enum: ["coder", "research", "read_only"],
              description:
                "Execution mode: 'coder' (default) or 'research' / 'read_only' (non-mutating inspection tools only)"
            },
            isolate_worktree: %{
              type: "boolean",
              description:
                "When true, runs the child agent inside an isolated temporary Git worktree and returns changed_files and diff_stat without modifying the parent checkout"
            }
          },
          required: ["objective"]
        }
      },
      %{
        name: "repo_map",
        description:
          "Generate a compact, bounded structural symbol map (modules, functions, types, behaviors, and top-level definitions) for workspace source files.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Optional relative file or directory subpath inside workspace"
            },
            focus_query: %{
              type: "string",
              description: "Optional search query ranking matching files and symbols first"
            },
            max_bytes: %{
              type: "integer",
              description: "Maximum output size in bytes (default 16000)"
            }
          }
        }
      },
      %{
        name: "diagnostics",
        description:
          "Run fast syntax checks across Elixir workspace files (or subpath) and optional Mix compiler verification, returning file:line [severity] message diagnostics.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Optional relative file or directory subpath inside workspace"
            },
            compile: %{
              type: "boolean",
              description:
                "When true, runs a Mix compiler check under exclusive project lock in addition to syntax checks"
            }
          }
        }
      },
      %{
        name: "find_references",
        description:
          "Find all AST-verified references to an Elixir module or function/macro symbol across workspace .ex/.exs files (definitions, aliases, imports, requires, uses, structs, calls, captures, and specs), ignoring comments and string literals.",
        parameters: %{
          type: "object",
          properties: %{
            symbol: %{
              type: "string",
              description:
                "Target Elixir symbol (e.g. 'MyApp.Accounts', 'MyApp.Accounts.get_user/1', or 'MyApp.Accounts.get_user')"
            },
            module: %{
              type: "string",
              description: "Optional module name when specifying module and function separately"
            },
            function: %{
              type: "string",
              description: "Optional function or macro name when specifying module + function"
            },
            arity: %{
              type: "integer",
              description: "Optional function arity filter when specifying module + function"
            },
            path: %{
              type: "string",
              description: "Optional relative file or directory subpath inside workspace"
            },
            limit: %{
              type: "integer",
              description: "Maximum references to return (default 200)"
            }
          },
          required: ["symbol"]
        }
      },
      %{
        name: "rename_symbol",
        description:
          "Safely rename an Elixir module or function/macro symbol across all workspace .ex/.exs files with AST scope resolution, pre-write syntax verification, and atomic rollback-safe commits.",
        parameters: %{
          type: "object",
          properties: %{
            symbol: %{
              type: "string",
              description:
                "Source Elixir symbol to rename (e.g. 'MyApp.OldMod', 'MyApp.Mod.old_fun/2', or 'MyApp.Mod.old_fun')"
            },
            new_name: %{
              type: "string",
              description:
                "Target module name (for module renames, e.g. 'MyApp.NewMod') or function name (for function renames, e.g. 'new_fun')"
            },
            dry_run: %{
              type: "boolean",
              description:
                "When true, previews unified diffs and occurrence counts without modifying files (default false)"
            },
            path: %{
              type: "string",
              description: "Optional relative file or directory subpath inside workspace"
            }
          },
          required: ["symbol", "new_name"]
        }
      },
      %{
        name: "lsp_query",
        description:
          "Query an external Language Server Protocol (LSP) server over stdio for definitions, references, hover documentation, or document symbols within workspace-contained files.",
        parameters: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              enum: ["definition", "references", "hover", "document_symbols"],
              description:
                "LSP query action: 'definition', 'references', 'hover', or 'document_symbols'"
            },
            file: %{
              type: "string",
              description:
                "Workspace-contained relative path, absolute path, or file:// URI to inspect"
            },
            line: %{
              type: "integer",
              description:
                "0-indexed line number (default 0; used by 'definition', 'references', and 'hover')"
            },
            character: %{
              type: "integer",
              description:
                "0-indexed character column offset (default 0; used by 'definition', 'references', and 'hover')"
            },
            server_cmd: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Optional explicit LSP server command and arguments (e.g. [\"typescript-language-server\", \"--stdio\"])"
            }
          },
          required: ["action", "file"]
        }
      }
    ]

    filter_tool_definitions(definitions ++ mcp_definitions(), allowlist)
  end

  defp mcp_definitions do
    IexCode.MCP.ToolBridge.definitions()
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  # --- Direct Delegations ---
  def ast_search(query, root_path \\ "."), do: ASTSearch.search(root_path, query)

  def find_references(symbol, root_path \\ ".", opts \\ []),
    do: SymbolRefactor.find_references(root_path, symbol, opts)

  def lsp_query(params, root_path \\ ".", opts \\ []),
    do: LSPClient.query(root_path, params, opts)

  def rename_symbol(from_spec, to_name, root_path \\ ".", opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    args = Map.put(trusted_lock_args(opts), "dry_run", dry_run?)

    with_mutation_locks("rename_symbol", args, root_path, fn ->
      SymbolRefactor.rename_symbol(root_path, from_spec, to_name, opts)
    end)
  end

  def multi_patch(patches, root_path \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "patches", patches)

    with_mutation_locks("multi_patch", args, root_path, fn ->
      MultiPatch.apply_patches(root_path, patches, opts)
    end)
  end

  def run_tests(opts \\ []) do
    root_path = Keyword.get(opts, :project_root, File.cwd!())
    args = trusted_lock_args(opts)
    normalized_opts = normalize_run_tests_opts(opts)

    with_mutation_locks("run_tests", args, root_path, fn -> TestRunner.run(normalized_opts) end)
  end

  def git_status(repo_dir \\ "."), do: Git.status(repo_dir)
  def git_diff(repo_dir \\ ".", opts \\ []), do: Git.diff(repo_dir, opts)

  def git_stage(files, repo_dir \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "files", files)

    with_mutation_locks("git_stage", args, repo_dir, fn ->
      Git.stage(files, repo_dir)
    end)
  end

  def git_commit(message, repo_dir \\ ".", opts \\ []) do
    args = Map.put(trusted_lock_args(opts), "message", message)

    with_mutation_locks("git_commit", args, repo_dir, fn ->
      Git.commit(message, repo_dir, opts)
    end)
  end

  def rollback_multi_patch(transaction_id, project_root, opts \\ []) do
    case Snapshot.get_snapshot(transaction_id) do
      {:ok, %{patches: patches}} ->
        args = Map.put(trusted_lock_args(opts), "patches", patches)

        with_mutation_locks("multi_patch", args, project_root, fn ->
          MultiPatch.rollback(transaction_id)
        end)

      _missing_or_invalid ->
        MultiPatch.rollback(transaction_id)
    end
  end

  def git_generate_commit(repo_dir \\ "."), do: Git.generate_commit_message(repo_dir)

  @doc """
  Executes a named tool with arguments inside the workspace `root_path`.
  Implementation crashes are contained and returned as `{:error, reason}`
  instead of propagating to callers.
  """
  def execute(tool_name, args, root_path, on_progress \\ fn _p, _msg -> :ok end) do
    canonical_tool = resolve_tool_alias(tool_name)

    result =
      with_mutation_locks(canonical_tool, args, root_path, fn identity_opts,
                                                              remaining_timeout_ms ->
        trusted_args =
          args
          |> Map.put("__workspace_lock_identity__", identity_opts)
          |> put_remaining_command_timeout(canonical_tool, remaining_timeout_ms)

        do_execute(canonical_tool, trusted_args, root_path, on_progress)
      end)

    if canonical_tool in ["read_file", "grep_search"],
      do: IexCode.Tools.NativeResponse.envelope(result),
      else: result
  rescue
    exception ->
      canonical_tool = resolve_tool_alias(tool_name)
      message = Exception.message(exception)

      message =
        if canonical_tool in ["read_file", "grep_search"],
          do: IexCode.Tools.NativeResponse.preview(message),
          else: message

      {:error, "Tool #{tool_name} crashed: #{message}"}
  end

  defp do_execute("read_file", %{"path" => path} = args, root_path, on_progress) do
    display_path = IexCode.Tools.NativeResponse.preview(path)
    on_progress.(10, "Resolving path: #{display_path}")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.exists?(full_path) do
          on_progress.(50, "Reading file bytes...")

          case IexCode.Tools.NativeRead.read(full_path, args) do
            {:ok, numbered, count} ->
              on_progress.(100, "Read finished (#{count} returned lines)")
              {:ok, numbered}

            {:error, reason} ->
              {:error, "Failed to read file #{display_path}: #{inspect(reason)}"}
          end
        else
          {:error, "File does not exist: #{display_path}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{display_path}"}
    end
  end

  defp do_execute(
         "write_file",
         %{"path" => path, "content" => content} = args,
         root_path,
         on_progress
       ) do
    on_progress.(20, "Creating parent directories for #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        session_id = Map.get(args, "session_id")
        file_existed = File.exists?(full_path)
        original_content = if file_existed, do: File.read!(full_path), else: nil

        File.mkdir_p!(Path.dirname(full_path))

        on_progress.(70, "Writing #{byte_size(content)} bytes to file...")

        case atomic_write(full_path, content) do
          :ok ->
            if session_id do
              patch = %{
                "path" => path,
                "file_existed" => file_existed,
                "original_content" => original_content,
                "new_content" => content
              }

              _ =
                IexCode.TimeTravel.create_checkpoint(%{
                  session_id: session_id,
                  project_root: root_path,
                  label: "write_file #{path}",
                  diff_summary: if(file_existed, do: "Updated #{path}", else: "Created #{path}"),
                  patches: [patch]
                })
            end

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
         %{"path" => path, "target_content" => target, "replacement_content" => replacement} =
           args,
         root_path,
         on_progress
       ) do
    on_progress.(20, "Reading target file #{path}...")

    case resolve_path(root_path, path) do
      {:ok, full_path} ->
        if File.exists?(full_path) do
          content = File.read!(full_path)
          anchor_line = parse_optional_positive_int(Map.get(args, "anchor_line"))
          allow_multiple = Map.get(args, "allow_multiple") == true

          patch_opts = [
            reject_ambiguous: true,
            allow_multiple: allow_multiple,
            anchor_line: anchor_line
          ]

          case MultiPatch.patch_string(content, target, replacement, patch_opts) do
            {:ok, %{content: new_content}} ->
              on_progress.(60, "Replacing target content...")

              case atomic_write(full_path, new_content) do
                :ok ->
                  session_id = Map.get(args, "session_id")

                  if session_id do
                    patch = %{
                      "path" => path,
                      "file_existed" => true,
                      "original_content" => content,
                      "new_content" => new_content
                    }

                    _ =
                      IexCode.TimeTravel.create_checkpoint(%{
                        session_id: session_id,
                        project_root: root_path,
                        label: "patch_file #{path}",
                        diff_summary: "Modified #{path}",
                        patches: [patch]
                      })
                  end

                  on_progress.(100, "Patched #{path} successfully")
                  {:ok, "Successfully patched #{path}"}

                {:error, reason} ->
                  {:error, "Failed to write patched file #{path}: #{inspect(reason)}"}
              end

            {:error, :not_found} ->
              diag = Matcher.diagnose_failure(content, target)
              {:error, "Target content not found in #{path}\n#{diag}"}

            {:error, {:ambiguous_match, match_lines}} ->
              diag = Matcher.diagnose_failure(content, target)

              {:error,
               "Ambiguous target in #{path} (matched lines: #{Enum.join(match_lines, ", ")})\n#{diag}"}
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

      {:error, {:target_not_found, rel_path, target}} ->
        diag = diagnose_workspace_patch_failure(root_path, rel_path, target)
        {:error, "MultiPatch failed: Target content not found in #{rel_path}#{diag}"}

      {:error, {:ambiguous_target, rel_path, match_lines}} ->
        candidate_target = find_patch_target_for_path(patches, rel_path)
        diag = diagnose_workspace_patch_failure(root_path, rel_path, candidate_target)

        {:error,
         "MultiPatch failed: Ambiguous target in #{rel_path} (matched lines: #{Enum.join(match_lines, ", ")})#{diag}"}

      {:error, reason} ->
        {:error, "MultiPatch failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("ast_search", args, root_path, on_progress) do
    on_progress.(30, "Scanning AST symbols in #{root_path}...")

    case ASTSearch.search(root_path, args, contain_root: true) do
      {:ok, results} ->
        on_progress.(100, "Found #{length(results)} matching symbols")
        formatted = ASTSearch.format_results(results, include_code: true)
        {:ok, formatted}

      {:error, reason} when reason in [:outside_workspace, :symlink_escapes_root] ->
        sub_path = arg_value(args, "path") || ""
        {:error, "Path escapes the workspace: #{sub_path}"}

      {:error, reason} ->
        {:error, "AST search failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("find_references", args, root_path, on_progress) do
    on_progress.(25, "Scanning AST symbol references in #{root_path}...")

    sub_path = nonempty_binary(arg_value(args, "path"))
    limit = parse_optional_positive_int(arg_value(args, "limit"))

    opts =
      []
      |> maybe_put_kw(:path, sub_path)
      |> maybe_put_kw(:limit, limit)

    case SymbolRefactor.find_references(root_path, args, opts) do
      {:ok, refs} ->
        on_progress.(100, "Found #{length(refs)} symbol reference(s)")
        fmt_opts = if limit, do: [limit: limit], else: []
        {:ok, SymbolRefactor.format_references(refs, fmt_opts)}

      {:error, reason} when reason in [:outside_workspace, :symlink_escapes_root] ->
        {:error, "Path escapes the workspace: #{sub_path || "."}"}

      {:error, reason} ->
        {:error, "find_references failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("rename_symbol", args, root_path, on_progress) do
    to_name =
      nonempty_binary(arg_value(args, "new_name")) ||
        nonempty_binary(arg_value(args, "to_name")) ||
        nonempty_binary(arg_value(args, "to"))

    raw_dry_run = arg_value(args, "dry_run")
    sub_path = nonempty_binary(arg_value(args, "path"))

    cond do
      is_nil(to_name) ->
        {:error, "rename_symbol failed: new_name is required"}

      not is_nil(raw_dry_run) and not is_boolean(raw_dry_run) ->
        {:error, "rename_symbol failed: dry_run must be a boolean"}

      true ->
        dry_run? = raw_dry_run == true
        from_spec = nonempty_binary(arg_value(args, "from")) || args

        on_progress.(
          25,
          if(dry_run?,
            do: "Previewing symbol rename to #{to_name}...",
            else: "Renaming symbol to #{to_name}..."
          )
        )

        opts = [dry_run: dry_run?] |> maybe_put_kw(:path, sub_path)

        case SymbolRefactor.rename_symbol(root_path, from_spec, to_name, opts) do
          {:ok, %{dry_run: true, files_changed: 0}} ->
            on_progress.(100, "Dry run complete (0 occurrences)")
            {:ok, "Dry run: 0 occurrences found (0 files would change)."}

          {:ok, %{dry_run: true} = summary} ->
            on_progress.(
              100,
              "Dry run complete (#{summary.occurrences} occurrence(s) across #{summary.files_changed} file(s))"
            )

            {:ok,
             "Dry run: would rename #{summary.occurrences} occurrence(s) across #{summary.files_changed} file(s).\n\n#{summary.diff}"}

          {:ok, %{dry_run: false, files_changed: 0}} ->
            on_progress.(100, "Rename complete (0 occurrences)")
            {:ok, "Renamed 0 occurrences across 0 files (no matching symbol references found)."}

          {:ok, %{dry_run: false} = summary} ->
            on_progress.(
              100,
              "Renamed #{summary.occurrences} occurrence(s) across #{summary.files_changed} file(s)"
            )

            {:ok,
             "Renamed #{summary.occurrences} occurrence(s) across #{summary.files_changed} file(s) (#{Enum.join(summary.files, ", ")}).\n\n#{summary.diff}"}

          {:error, reason} when reason in [:outside_workspace, :symlink_escapes_root] ->
            {:error, "Path escapes the workspace: #{sub_path || "."}"}

          {:error, reason} ->
            {:error, "rename_symbol failed: #{inspect(reason)}"}
        end
    end
  end

  defp do_execute("lsp_query", args, root_path, on_progress) do
    action = normalize_lsp_action(arg_value(args, "action"))
    file = nonempty_binary(arg_value(args, "file")) || nonempty_binary(arg_value(args, "path"))
    line_res = parse_lsp_non_neg_int(arg_value(args, "line"), 0)
    char_res = parse_lsp_non_neg_int(arg_value(args, "character"), 0)
    cmd_res = normalize_lsp_server_cmd(arg_value(args, "server_cmd"))
    timeout_ms = parse_optional_positive_int(arg_value(args, "timeout_ms"))
    include_decl = arg_value(args, "include_declaration")

    cond do
      is_nil(action) ->
        {:error, "lsp_query failed: action is required"}

      action not in ["definition", "references", "hover", "document_symbols"] ->
        {:error,
         "lsp_query failed: unsupported action #{inspect(action)} (expected definition, references, hover, or document_symbols)"}

      is_nil(file) ->
        {:error, "lsp_query failed: file is required"}

      match?({:error, _}, line_res) ->
        {:error, "lsp_query failed: line must be a non-negative integer"}

      match?({:error, _}, char_res) ->
        {:error, "lsp_query failed: character must be a non-negative integer"}

      match?({:error, _}, cmd_res) ->
        {:error, "lsp_query failed: server_cmd must be a non-empty string or list of strings"}

      true ->
        {:ok, line} = line_res
        {:ok, character} = char_res
        {:ok, server_cmd} = cmd_res

        on_progress.(20, "Resolving workspace containment for #{file}...")

        case LSPClient.resolve_uri_in_root(root_path, file) do
          {:ok, canonical_file, _uri} ->
            if File.regular?(canonical_file) do
              on_progress.(50, "Running LSP #{action} query on #{file}...")

              query_opts =
                [file: canonical_file, line: line, character: character]
                |> maybe_put_kw(:server_cmd, server_cmd)
                |> maybe_put_kw(:timeout_ms, timeout_ms)
                |> maybe_put_kw(
                  :include_declaration,
                  if(is_boolean(include_decl), do: include_decl, else: nil)
                )

              case LSPClient.query(root_path, action, query_opts) do
                {:ok, result} ->
                  on_progress.(100, "LSP #{action} query complete")
                  {:ok, format_lsp_result(action, result, root_path)}

                {:error, reason} when reason in [:outside_workspace, :symlink_escapes_root] ->
                  {:error,
                   "Path escapes the workspace: LSP server returned an out-of-workspace URI"}

                {:error, {:lsp_server_unavailable, ext}} ->
                  {:error, "lsp_query failed: no LSP server available on PATH for #{ext}"}

                {:error, {:lsp_error, code, message}} ->
                  {:error, "LSP server error (#{code}): #{message}"}

                {:error, reason} ->
                  {:error, "lsp_query failed: #{inspect(reason)}"}
              end
            else
              {:error, "File does not exist: #{file}"}
            end

          {:error, reason}
          when reason in [:outside_workspace, :symlink_escapes_root, :too_many_symlinks] ->
            {:error, "Path escapes the workspace: #{file}"}

          {:error, :unsupported_uri_scheme} ->
            {:error, "lsp_query failed: unsupported URI scheme in #{file}"}

          {:error, :invalid_file_uri} ->
            {:error, "lsp_query failed: invalid file URI #{file}"}

          {:error, reason} ->
            {:error, "lsp_query failed: #{inspect(reason)}"}
        end
    end
  end

  defp do_execute("repo_map", args, root_path, on_progress) do
    on_progress.(25, "Building structural repository map...")

    case RepoMap.generate(root_path, args) do
      {:ok, map_text} ->
        on_progress.(100, "Repo map generated")
        {:ok, map_text}

      {:error, reason} ->
        {:error, "RepoMap failed: #{reason}"}
    end
  end

  defp do_execute("diagnostics", args, root_path, on_progress) do
    subpath = nonempty_binary(arg_value(args, "path")) || "."
    compile? = arg_value(args, "compile") == true

    on_progress.(20, "Running diagnostics for #{subpath}...")

    case resolve_path(root_path, subpath) do
      {:ok, target_path} ->
        if File.exists?(target_path) do
          elixir_files = collect_elixir_files(target_path)
          syntax_diags = scan_syntax_diagnostics(root_path, elixir_files)

          compile_diags =
            if compile? and File.exists?(Path.join(root_path, "mix.exs")) do
              on_progress.(60, "Running Mix compiler diagnostics...")
              run_compile_diagnostics(root_path, subpath)
            else
              {:ok, []}
            end

          case compile_diags do
            {:ok, compiler_items} ->
              all_items =
                (syntax_diags ++ compiler_items)
                |> Enum.uniq_by(&{&1.file, &1.line, &1.severity, &1.message})
                |> Enum.sort_by(&{&1.file, &1.line, &1.severity})

              on_progress.(100, "Diagnostics complete (#{length(all_items)} issue(s))")

              if all_items == [] do
                {:ok, "No diagnostics found (#{length(elixir_files)} Elixir file(s) checked)."}
              else
                formatted =
                  Enum.map_join(all_items, "\n", fn item ->
                    "#{item.file}:#{item.line} [#{item.severity}] #{item.message}"
                  end)

                {:ok, formatted}
              end

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, "Path does not exist: #{subpath}"}
        end

      {:error, :outside_workspace} ->
        {:error, "Path escapes the workspace: #{subpath}"}
    end
  end

  defp do_execute("semantic_code_search", %{"query" => query} = args, root_path, on_progress) do
    on_progress.(20, "Executing semantic code search...")
    limit = Map.get(args, "limit", 10)
    threshold = Map.get(args, "threshold", 0.4)
    path = Map.get(args, "path")

    mode =
      case arg_value(args, "mode") do
        nil -> :hybrid
        "" -> :hybrid
        other -> other
      end

    project_id = resolve_semantic_project_id(args, root_path)

    if IexCode.SemanticIndex.Indexer.stats(project_id).ets_chunks == 0 do
      on_progress.(40, "Indexing codebase chunks...")
      _ = IexCode.SemanticIndex.Indexer.index_project(project_id, root_path)
    end

    on_progress.(70, "Computing code retrieval ranking...")

    search_opts = [
      limit: limit,
      threshold: threshold,
      mode: mode
    ]

    search_opts = if path, do: Keyword.put(search_opts, :path, path), else: search_opts

    case IexCode.SemanticIndex.Indexer.search(project_id, query, search_opts) do
      {:ok, []} ->
        on_progress.(100, "Search completed (0 matches)")
        {:ok, "No matching code snippets found for query: \"#{query}\""}

      {:ok, matches} ->
        on_progress.(100, "Found #{length(matches)} matches")

        formatted =
          Enum.map_join(matches, "\n\n---\n\n", fn m ->
            header = "[Match: #{m.match_percent}%] #{m.file_path}:#{m.start_line}-#{m.end_line}"
            sym = if m.symbol_name, do: " (#{m.symbol_type} #{m.symbol_name})", else: ""
            "#{header}#{sym}\n#{m.content}"
          end)

        {:ok, "Found #{length(matches)} semantic matches:\n\n#{formatted}"}

      {:error, reason} ->
        {:error, "Semantic search failed: #{inspect(reason)}"}
    end
  end

  defp do_execute("run_tests", args, root_path, on_progress) do
    opts =
      [project_root: root_path, on_progress: on_progress]
      |> add_opt_from_map(args, "paths", :paths)
      |> add_opt_from_map(args, "line", :line)
      |> add_opt_from_map(args, "changed", :changed)
      |> add_opt_from_map(args, "changed_files", :changed_files)
      |> add_opt_from_map(args, "failed", :failed)
      |> add_opt_from_map(args, "stale", :stale)
      |> add_opt_from_map(args, "partition", :partition)
      |> add_opt_from_map(args, "seed", :seed)
      |> add_opt_from_map(args, "timeout_ms", :timeout_ms)
      |> normalize_run_tests_opts()

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
    with :ok <- IexCode.Tools.NativeGrep.validate_query(query) do
      sub_path = Map.get(args, "path", "") || ""
      case_sensitive? = Map.get(args, "case_sensitive", false)

      case resolve_path(root_path, sub_path) do
        {:ok, search_dir} ->
          on_progress.(
            30,
            "Scanning files in #{IexCode.Tools.NativeResponse.preview(search_dir)} for query '#{IexCode.Tools.NativeResponse.preview(query)}'..."
          )

          case IexCode.Tools.NativeGrep.search(root_path, search_dir, query, case_sensitive?) do
            {:ok, output, count} ->
              on_progress.(100, "Search finished (#{count} returned matches)")
              {:ok, output}

            {:error, message} ->
              {:error, message}
          end

        {:error, :outside_workspace} ->
          {:error,
           "Path escapes the workspace: #{IexCode.Tools.NativeResponse.preview(sub_path)}"}
      end
    end
  end

  defp do_execute("run_command", %{"sandbox_policy" => policy} = args, root_path, on_progress)
       when is_map(policy) do
    run_sandboxed_command(args, policy, root_path, on_progress)
  end

  defp do_execute("run_command", args, root_path, on_progress) do
    command = Map.get(args, "command") || Map.get(args, :command)
    session_id = Map.get(args, "session_id") || Map.get(args, :session_id)
    timeout = Map.get(args, "timeout_ms") || Map.get(args, :timeout_ms) || 30_000
    requested_timeout = Map.get(args, "__requested_timeout_ms__", timeout)
    agent_name = Map.get(args, "agent_name") || Map.get(args, :agent_name) || "Agent"
    op_id = Map.get(args, "op_id") || Map.get(args, :op_id)

    settings =
      Map.get(args, "__settings__") ||
        Map.get(args, :settings) ||
        IexCode.Settings.get_settings()

    known_secrets =
      [
        settings.openai_api_key,
        settings.anthropic_api_key
        | Map.values(settings.custom_env_vars || %{})
      ]
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))

    if session_id && session_id != "" do
      on_progress.(20, "Executing agent command in terminal: #{command}")

      case TerminalServer.run_agent_command(session_id, command, agent_name,
             timeout_ms: timeout,
             op_id: op_id,
             workspace_path: root_path,
             workspace_lock_identity: Map.get(args, "__workspace_lock_identity__", [])
           ) do
        {:ok, %{exit_code: 0, output: output}} ->
          on_progress.(100, "Command exited successfully (0)")
          {:ok, IexCode.Tools.SecretMasker.scrub(output, known_secrets)}

        {:ok, %{exit_code: exit_code, output: output}} ->
          on_progress.(100, "Command failed (code #{exit_code})")
          scrubbed = IexCode.Tools.SecretMasker.scrub(output, known_secrets)
          {:ok, "Exit Code #{exit_code}:\n#{scrubbed}"}

        {:error, :timeout} ->
          on_progress.(100, "Command timed out after #{requested_timeout}ms")
          {:error, "Command timed out after #{requested_timeout}ms"}

        {:error, reason} ->
          on_progress.(100, "Command failed: #{inspect(reason)}")
          {:error, "Command failed: #{inspect(reason)}"}
      end
    else
      on_progress.(20, "Starting command: #{command} in #{root_path}")

      sandbox_mode =
        Map.get(args, "sandbox_mode") ||
          Map.get(args, :sandbox_mode) ||
          settings.sandbox_mode ||
          "inherit_filtered"

      custom_env =
        Map.merge(
          settings.custom_env_vars || %{},
          Map.get(args, "env") || Map.get(args, :env) || %{}
        )

      env_map = IexCode.Tools.SecretMasker.build_sandbox_env(sandbox_mode, custom_env, root_path)

      case ProcessGroupRunner.run(command,
             cd: root_path,
             env: env_map,
             timeout_ms: timeout,
             max_output_bytes: @max_command_output
           ) do
        {:ok, %{exit_code: exit_code, output: output, truncated?: truncated?}} ->
          output = finalize_command_output(output, truncated?, known_secrets)

          if exit_code == 0 do
            on_progress.(100, "Command exited successfully (0)")
            {:ok, output}
          else
            on_progress.(100, "Command failed (code #{exit_code})")
            {:ok, "Exit Code #{exit_code}:\n#{output}"}
          end

        {:timeout, %{output: output, truncated?: truncated?}} ->
          on_progress.(100, "Command timed out after #{requested_timeout}ms")
          scrubbed_partial = finalize_command_output(output, truncated?, known_secrets)

          {:error,
           "Command timed out after #{requested_timeout}ms. Partial output:\n#{scrubbed_partial}"}

        {:error, reason} ->
          on_progress.(100, "Command failed: #{inspect(reason)}")
          {:error, "Command failed: #{inspect(reason)}"}
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

  defp do_execute("update_plan", args, _root_path, on_progress) do
    with {:ok, run_id} <- autonomy_run_id(args),
         {:ok, steps} <- autonomy_steps(args),
         {:ok, normalized} <- IexCode.Engine.PlanStore.update_plan(run_id, steps) do
      on_progress.(100, "Plan updated with #{length(normalized)} steps")
      {:ok, %{"steps" => length(normalized), "run_id" => run_id}}
    end
  end

  defp do_execute("request_input", args, _root_path, on_progress) do
    with {:ok, run_id} <- autonomy_run_id(args),
         {:ok, question} <- autonomy_question(args) do
      options = args |> Map.get("options", []) |> List.wrap() |> Enum.take(10)

      request = %{
        "type" => "input_request",
        "run_id" => run_id,
        "question" => question,
        "options" => options
      }

      :ok = IexCode.Engine.PlanStore.put_input_request(run_id, request)
      on_progress.(100, "Run paused waiting for user input")
      {:pause, request}
    end
  end

  defp do_execute("spawn_agent", args, root_path, on_progress) do
    with {:ok, run_id} <- autonomy_run_id(args),
         {:ok, objective} <- autonomy_objective(args),
         {:ok, context} <- sub_agent_context(args) do
      child_context =
        context
        |> maybe_put_sub_agent_opt(args, "max_turns", :max_turns)
        |> maybe_put_sub_agent_opt(args, "mode", :mode)
        |> maybe_put_sub_agent_opt(args, "isolate_worktree", :isolate_worktree)

      on_progress.(10, "Spawning child agent: #{String.slice(objective, 0, 80)}")

      IexCode.Engine.SubAgent.run(
        run_id,
        objective,
        root_path,
        child_context,
        on_progress
      )
    end
  end

  defp do_execute("mcp__" <> _rest = name, args, _root_path, on_progress) do
    on_progress.(10, "Calling MCP tool #{name}...")

    case IexCode.MCP.ToolBridge.split(name) do
      {:ok, _server, _tool} -> IexCode.MCP.ToolBridge.execute(IexCode.MCP.Manager, name, args)
      {:error, _reason} = error -> error
    end
  end

  defp do_execute(unknown_tool, _args, _root_path, _on_progress) do
    {:error, "Unknown tool: #{unknown_tool}"}
  end

  defp run_sandboxed_command(args, policy_params, root_path, on_progress) do
    command = Map.get(args, "command") || Map.get(args, :command)
    timeout = Map.get(args, "timeout_ms") || Map.get(args, :timeout_ms) || 30_000
    server = Map.get(args, "__sandbox_server__", IexCode.Sandbox.Manager)
    backend = Map.get(args, "__sandbox_backend__")

    settings = IexCode.Settings.get_settings()

    known_secrets =
      [
        settings.openai_api_key,
        settings.anthropic_api_key
        | Map.values(settings.custom_env_vars || %{})
      ]
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))

    with {:ok, policy} <- IexCode.Sandbox.Policy.from_map(policy_params),
         {:ok, result} <-
           IexCode.Sandbox.Manager.run(
             ["sh", "-c", command],
             policy,
             workdir: root_path,
             timeout_ms: timeout,
             server: server,
             backend: backend || IexCode.Sandbox.Backend.detect()
           ) do
      on_progress.(100, "Sandboxed command exited (#{result.exit_code})")
      output = IexCode.Tools.SecretMasker.scrub(result.output, known_secrets)

      if result.exit_code == 0 do
        {:ok, output}
      else
        {:ok, "Exit Code #{result.exit_code}:\n#{output}"}
      end
    else
      {:error, reason} ->
        on_progress.(100, "Sandboxed command failed: #{inspect(reason)}")
        {:error, "Sandboxed command failed: #{inspect(reason)}"}
    end
  end

  defp autonomy_run_id(args) do
    case Map.get(args, "run_id") || Map.get(args, :run_id) do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _missing -> {:error, :missing_run_context}
    end
  end

  defp autonomy_steps(%{"steps" => steps}) when is_list(steps), do: {:ok, steps}
  defp autonomy_steps(%{steps: steps}) when is_list(steps), do: {:ok, steps}
  defp autonomy_steps(_args), do: {:error, :plan_steps_must_be_a_list}

  defp autonomy_question(args) do
    case Map.get(args, "question") || Map.get(args, :question) do
      question when is_binary(question) ->
        trimmed = String.trim(question)
        if trimmed == "", do: {:error, :input_question_required}, else: {:ok, trimmed}

      _missing ->
        {:error, :input_question_required}
    end
  end

  defp autonomy_objective(args) do
    case Map.get(args, "objective") || Map.get(args, :objective) do
      objective when is_binary(objective) ->
        trimmed = String.trim(objective)
        if trimmed == "", do: {:error, :spawn_objective_required}, else: {:ok, trimmed}

      _missing ->
        {:error, :spawn_objective_required}
    end
  end

  # Loop-injected trusted context (modules are never taken from model args).
  defp sub_agent_context(%{"__sub_agent__" => context}) when is_map(context), do: {:ok, context}
  defp sub_agent_context(_args), do: {:error, :requires_agent_loop}

  defp resolve_path(root_path, path) do
    case WorkspacePath.resolve(root_path, path) do
      {:ok, full_path} -> {:ok, full_path}
      {:error, _reason} -> {:error, :outside_workspace}
    end
  end

  # All opaque or directly mutating tools enter the durable workspace-lock gateway
  # before they inspect or change native workspace state. Keeping this gate at the
  # semantic tool boundary also covers direct agent calls and ensures MultiPatch
  # declares its complete file set before its planning phase begins.
  defp with_mutation_locks(tool_name, args, root_path, fun)
       when is_function(fun, 0) or is_function(fun, 1) or is_function(fun, 2) do
    case mutation_resources(tool_name, args) do
      [] ->
        invoke_locked_fun(fun, [], nil)

      resources ->
        with {:ok, project_or_root, identity_opts} <-
               resolve_lock_identity(root_path, args) do
          result =
            if wait_for_command_lock?(tool_name, args) do
              with_waiting_command_lock(project_or_root, resources, identity_opts, args, fun)
            else
              IexCode.WorkspaceLocks.with_locks(
                project_or_root,
                resources,
                identity_opts,
                fn -> invoke_with_active_identity(fun, identity_opts, nil) end
              )
            end

          case result do
            {:error, {:conflict, locks}} -> {:error, {:workspace_lock_waiting, locks}}
            result -> result
          end
        end
    end
  end

  defp with_waiting_command_lock(project_or_root, resources, identity_opts, args, fun) do
    timeout_ms = normalize_command_timeout(arg_value(args, "timeout_ms", 30_000))
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case IexCode.WorkspaceLocks.acquire_or_wait(project_or_root, resources, identity_opts) do
      {:ok, handle} -> run_with_command_handle(handle, identity_opts, deadline, fun)
      {:waiting, handle} -> retry_command_lock(handle, identity_opts, deadline, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  # Persisted application callers fail closed immediately so the UI can surface
  # the owning run/session. Legacy PTY callers without a durable project id keep
  # their historical synchronous contract by waiting within their command budget.
  defp wait_for_command_lock?("run_command", args),
    do: is_nil(nonempty_binary(arg_value(args, "project_id")))

  defp wait_for_command_lock?(_tool_name, _args), do: false

  defp retry_command_lock(handle, identity_opts, deadline, fun) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      locks = Map.get(handle, :locks, [])
      _ = IexCode.WorkspaceLocks.release(handle)
      {:error, {:workspace_lock_waiting, locks}}
    else
      receive do
      after
        min(25, remaining) -> :ok
      end

      case IexCode.WorkspaceLocks.retry(handle) do
        {:ok, held_handle} ->
          run_with_command_handle(held_handle, identity_opts, deadline, fun)

        {:waiting, waiting_handle} ->
          retry_command_lock(waiting_handle, identity_opts, deadline, fun)

        {:error, reason} ->
          _ = IexCode.WorkspaceLocks.release(handle)
          {:error, reason}
      end
    end
  end

  defp run_with_command_handle(handle, identity_opts, deadline, fun) do
    try do
      IexCode.WorkspaceLocks.with_delegation(handle, fn ->
        case IexCode.WorkspaceLocks.assert(handle) do
          :ok ->
            remaining = max(deadline - System.monotonic_time(:millisecond), 1)
            invoke_with_active_identity(fun, identity_opts, remaining)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    after
      _ = IexCode.WorkspaceLocks.release(handle)
    end
  end

  defp invoke_with_active_identity(fun, identity_opts, remaining_timeout_ms) do
    active_identity_opts =
      Keyword.put(
        identity_opts,
        :delegation,
        IexCode.WorkspaceLocks.current_delegation()
      )

    invoke_locked_fun(fun, active_identity_opts, remaining_timeout_ms)
  end

  defp invoke_locked_fun(fun, _identity_opts, _remaining_timeout_ms) when is_function(fun, 0),
    do: fun.()

  defp invoke_locked_fun(fun, identity_opts, _remaining_timeout_ms) when is_function(fun, 1),
    do: fun.(identity_opts)

  defp invoke_locked_fun(fun, identity_opts, remaining_timeout_ms) when is_function(fun, 2),
    do: fun.(identity_opts, remaining_timeout_ms)

  defp mutation_resources("write_file", args), do: file_resources(args, ["path"])
  defp mutation_resources("patch_file", args), do: file_resources(args, ["path"])

  defp mutation_resources("multi_patch", args) do
    args
    |> arg_value("patches", [])
    |> List.wrap()
    |> Enum.map(&arg_value(&1, "path"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&{{:file, &1}, :write})
  end

  defp mutation_resources("run_command", _args), do: [{:project, :exclusive}]
  defp mutation_resources("run_tests", _args), do: [{:project, :exclusive}]

  defp mutation_resources("diagnostics", args) do
    if arg_value(args, "compile") == true, do: [{:project, :exclusive}], else: []
  end

  defp mutation_resources("rename_symbol", args) do
    if arg_value(args, "dry_run") == true, do: [], else: [{:project, :exclusive}]
  end

  defp mutation_resources("git_stage", _args), do: [{:git, :exclusive}]
  defp mutation_resources("git_commit", _args), do: [{:git, :exclusive}]
  defp mutation_resources(_tool_name, _args), do: []

  defp file_resources(args, keys) do
    keys
    |> Enum.map(&arg_value(args, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&{{:file, &1}, :write})
  end

  defp resolve_lock_identity(root_path, args) when is_binary(root_path) and is_map(args) do
    project_id = arg_value(args, "project_id")

    with {:ok, project_or_root, allow_unmanaged?} <-
           resolve_lock_project(project_id, root_path) do
      requested_run_id = nonempty_binary(arg_value(args, "run_id"))
      routing_session_id = nonempty_binary(arg_value(args, "session_id"))

      durable_session_id =
        trusted_lock_session_id(project_or_root, project_id, routing_session_id)

      durable_run_id =
        trusted_lock_run_id(
          project_or_root,
          project_id,
          requested_run_id,
          durable_session_id
        )

      identity_opts =
        [
          owner_id: lock_owner_id(durable_run_id, routing_session_id),
          project_id: if(match?(%Project{}, project_or_root), do: project_or_root.id),
          run_id: durable_run_id,
          session_id: durable_session_id,
          delegation: IexCode.WorkspaceLocks.current_delegation(),
          allow_unmanaged: allow_unmanaged?
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, project_or_root, identity_opts}
    end
  end

  defp resolve_lock_identity(_root_path, _args), do: {:error, :invalid_workspace}

  defp resolve_lock_project(project_id, root_path)
       when is_binary(project_id) and project_id != "" do
    case fetch_project(project_id) do
      %Project{} = project ->
        if same_workspace?(project.root_path, root_path) do
          {:ok, project, false}
        else
          {:error, :project_workspace_mismatch}
        end

      nil ->
        {:error, :invalid_project}
    end
  end

  defp resolve_lock_project(_project_id, root_path), do: {:ok, root_path, true}

  defp fetch_project(project_id) do
    Projects.get_project!(project_id)
  rescue
    _ in [Ecto.NoResultsError, Ecto.Query.CastError] -> nil
  end

  # A terminal routing id is not automatically a durable lock identity. Legacy
  # callers and tests often use arbitrary PTY ids; binding those as a foreign key
  # would reject an otherwise valid native command. Only a caller that supplied a
  # validated project id may attach a persisted session belonging to that project.
  defp trusted_lock_session_id(
         %Project{id: project_id},
         project_id,
         session_id
       )
       when is_binary(session_id) do
    case Sessions.get_session(session_id) do
      %{project_id: ^project_id} -> session_id
      _ -> nil
    end
  end

  defp trusted_lock_session_id(_project_or_root, _project_id, _session_id), do: nil

  defp trusted_lock_run_id(
         %Project{id: project_id},
         project_id,
         run_id,
         session_id
       )
       when is_binary(run_id) and is_binary(session_id) do
    case Runs.get_run(run_id) do
      %{project_id: ^project_id, session_id: ^session_id} -> run_id
      _ -> nil
    end
  rescue
    _ in [Ecto.Query.CastError] -> nil
  end

  defp trusted_lock_run_id(_project_or_root, _project_id, _run_id, _session_id), do: nil

  defp same_workspace?(registered_root, requested_root) do
    with {:ok, canonical_registered} <- WorkspacePath.resolve(registered_root, ""),
         {:ok, canonical_requested} <- WorkspacePath.resolve(requested_root, "") do
      canonical_registered == canonical_requested
    else
      _ -> false
    end
  end

  defp lock_owner_id(run_id, _session_id) when is_binary(run_id), do: "run:#{run_id}"

  defp lock_owner_id(_run_id, session_id) when is_binary(session_id),
    do: "session:#{session_id}:tool:#{unique_lock_owner_suffix()}"

  defp lock_owner_id(_run_id, _session_id) do
    "tool:#{unique_lock_owner_suffix()}"
  end

  defp unique_lock_owner_suffix,
    do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  defp trusted_lock_args(opts) do
    %{
      "project_id" => Keyword.get(opts, :project_id),
      "run_id" => Keyword.get(opts, :run_id),
      "session_id" => Keyword.get(opts, :session_id)
    }
  end

  defp arg_value(map, key, default \\ nil)

  defp arg_value(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_existing_atom(key), default)
    end
  end

  defp arg_value(_map, _key, default), do: default

  defp safe_existing_atom("path"), do: :path
  defp safe_existing_atom("patches"), do: :patches
  defp safe_existing_atom("compile"), do: :compile
  defp safe_existing_atom("dry_run"), do: :dry_run
  defp safe_existing_atom("mode"), do: :mode
  defp safe_existing_atom("symbol"), do: :symbol
  defp safe_existing_atom("new_name"), do: :new_name
  defp safe_existing_atom("to_name"), do: :to_name
  defp safe_existing_atom("to"), do: :to
  defp safe_existing_atom("from"), do: :from
  defp safe_existing_atom("limit"), do: :limit
  defp safe_existing_atom("action"), do: :action
  defp safe_existing_atom("file"), do: :file
  defp safe_existing_atom("line"), do: :line
  defp safe_existing_atom("character"), do: :character
  defp safe_existing_atom("server_cmd"), do: :server_cmd
  defp safe_existing_atom("include_declaration"), do: :include_declaration
  defp safe_existing_atom("timeout_ms"), do: :timeout_ms
  defp safe_existing_atom("project_id"), do: :project_id
  defp safe_existing_atom("run_id"), do: :run_id
  defp safe_existing_atom("session_id"), do: :session_id
  defp safe_existing_atom(_key), do: :__unknown_lock_arg__

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)

  defp resolve_semantic_project_id(args, root_path) do
    case nonempty_binary(arg_value(args, "project_id")) do
      explicit when is_binary(explicit) ->
        explicit

      nil ->
        projects =
          case IexCode.Projects.list_projects() do
            list when is_list(list) -> list
            _ -> []
          end

        case Enum.find(
               projects,
               &(&1.root_path == root_path or same_workspace?(&1.root_path, root_path))
             ) do
          %Project{id: id} ->
            id

          nil ->
            case IexCode.Projects.get_or_create_project(root_path) do
              {:ok, %Project{id: id}} ->
                id

              _ ->
                case List.first(projects) do
                  %Project{id: id} -> id
                  _ -> "default"
                end
            end
        end
    end
  rescue
    _ -> "default"
  end

  defp nonempty_binary(value) when is_binary(value) and value != "", do: value
  defp nonempty_binary(_value), do: nil

  defp normalize_command_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_command_timeout(_value), do: 30_000

  defp put_remaining_command_timeout(args, "run_command", remaining)
       when is_integer(remaining) and remaining > 0 do
    requested = normalize_command_timeout(arg_value(args, "timeout_ms", 30_000))

    args
    |> Map.put("__requested_timeout_ms__", requested)
    |> Map.put("timeout_ms", remaining)
  end

  defp put_remaining_command_timeout(args, _tool_name, _remaining), do: args

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

  defp finalize_command_output(output, truncated?, known_secrets) do
    suffix =
      if truncated? do
        "\n\n[output truncated at #{@max_command_output} bytes]"
      else
        ""
      end

    (IexCode.Sessions.sanitize_utf8(output) <> suffix)
    |> IexCode.Tools.SecretMasker.scrub(known_secrets)
  end

  defp resolve_tool_alias(tool_name) when is_atom(tool_name) do
    tool_name |> Atom.to_string() |> resolve_tool_alias()
  end

  defp resolve_tool_alias(tool_name) when is_binary(tool_name) do
    Map.get(@tool_aliases, tool_name, tool_name)
  end

  defp resolve_tool_alias(other), do: other

  defp parse_optional_positive_int(val) when is_integer(val) and val >= 1, do: val

  defp parse_optional_positive_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {parsed, ""} when parsed >= 1 -> parsed
      _ -> nil
    end
  end

  defp parse_optional_positive_int(_), do: nil

  defp diagnose_workspace_patch_failure(_root_path, _rel_path, nil), do: ""

  defp diagnose_workspace_patch_failure(root_path, rel_path, target) when is_binary(target) do
    case resolve_path(root_path, rel_path) do
      {:ok, full_path} ->
        if File.regular?(full_path) do
          "\n" <> Matcher.diagnose_failure(File.read!(full_path), target)
        else
          ""
        end

      {:error, _} ->
        ""
    end
  end

  defp find_patch_target_for_path(patches, rel_path) when is_list(patches) do
    Enum.find_value(patches, fn patch ->
      path = Map.get(patch, :path) || Map.get(patch, "path")

      if path == rel_path do
        Map.get(patch, :target) ||
          Map.get(patch, "target") ||
          Map.get(patch, :target_content) ||
          Map.get(patch, "target_content")
      end
    end)
  end

  defp find_patch_target_for_path(_, _), do: nil

  defp collect_elixir_files(target_path) do
    cond do
      File.regular?(target_path) ->
        if Path.extname(target_path) in [".ex", ".exs"], do: [target_path], else: []

      File.dir?(target_path) ->
        target_path
        |> walk_elixir_files([])
        |> Enum.sort()

      true ->
        []
    end
  end

  defp walk_elixir_files(dir, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, inner_acc ->
          full_path = Path.join(dir, name)

          case File.lstat(full_path) do
            {:ok, %File.Stat{type: :directory}} ->
              if MapSet.member?(@diagnostics_excluded_dirs, name),
                do: inner_acc,
                else: walk_elixir_files(full_path, inner_acc)

            {:ok, %File.Stat{type: :regular}} ->
              if Path.extname(name) in [".ex", ".exs"],
                do: [full_path | inner_acc],
                else: inner_acc

            _ ->
              inner_acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp scan_syntax_diagnostics(root_path, files) do
    canonical_root =
      case WorkspacePath.resolve(root_path, ".") do
        {:ok, resolved} -> resolved
        {:error, _} -> Path.expand(root_path)
      end

    Enum.flat_map(files, fn abs_path ->
      rel = Path.relative_to(abs_path, canonical_root)
      content = File.read!(abs_path)

      case Code.string_to_quoted(content, file: rel, columns: true) do
        {:ok, _ast} ->
          []

        {:error, error_tuple} ->
          {line, msg} = format_syntax_diagnostic(error_tuple)
          [%{file: rel, line: line, severity: "error", message: msg}]
      end
    end)
  end

  defp format_syntax_diagnostic({meta, info, token}) do
    line =
      cond do
        is_list(meta) -> Keyword.get(meta, :line, 1)
        is_integer(meta) and meta >= 1 -> meta
        true -> 1
      end

    message =
      case {info, token} do
        {{prefix, suffix}, tok} when is_binary(prefix) and is_binary(suffix) ->
          String.trim("#{prefix}#{tok}#{suffix}")

        {prefix, tok} when is_binary(prefix) and is_binary(tok) ->
          String.trim("#{prefix}#{tok}")

        {other, tok} ->
          String.trim("#{inspect(other)}#{tok}")
      end

    {line, message}
  end

  defp format_syntax_diagnostic(other), do: {1, inspect(other)}

  defp run_compile_diagnostics(root_path, subpath) do
    env_map = IexCode.Tools.SecretMasker.build_sandbox_env("inherit_filtered", %{}, root_path)

    case ProcessGroupRunner.run("mix compile",
           cd: root_path,
           env: env_map,
           timeout_ms: 60_000,
           max_output_bytes: @max_command_output
         ) do
      {:ok, %{exit_code: exit_code, output: raw_output}} ->
        clean =
          raw_output
          |> Sessions.sanitize_utf8()
          |> TestRunner.Parser.strip_ansi()

        parsed = TestRunner.Parser.parse(clean, exit_code)

        parser_items =
          Enum.map(parsed.compilation_errors, fn err ->
            %{
              file: normalize_diag_file(err.file, root_path),
              line: err.line || 1,
              severity: "error",
              message: err.message
            }
          end)

        block_items = parse_elixir_compiler_blocks(clean, root_path)
        items = parser_items ++ block_items

        items =
          if exit_code != 0 and items == [] do
            first_msg =
              clean
              |> String.split(~r/\r?\n/)
              |> Enum.map(&String.trim/1)
              |> Enum.find("mix compile exited with code #{exit_code}", &(&1 != ""))

            [%{file: fallback_diag_file(subpath), line: 1, severity: "error", message: first_msg}]
          else
            items
          end

        {:ok, filter_diagnostics_by_subpath(items, subpath)}

      {:timeout, _info} ->
        {:error, "Diagnostics compile check timed out after 60000ms"}

      {:error, reason} ->
        {:error, "Diagnostics compile check failed: #{inspect(reason)}"}
    end
  end

  defp parse_elixir_compiler_blocks(clean_output, root_path) do
    lines = String.split(clean_output, ~r/\r?\n/)
    do_parse_compiler_blocks(lines, nil, root_path, [])
  end

  defp do_parse_compiler_blocks([], _current, _root_path, acc), do: Enum.reverse(acc)

  defp do_parse_compiler_blocks([line | rest], current, root_path, acc) do
    trimmed = String.trim(line)

    case Regex.run(~r/^(warning|error):\s+(.+)$/, trimmed) do
      [_, severity, msg] ->
        do_parse_compiler_blocks(rest, {severity, String.trim(msg)}, root_path, acc)

      nil when current != nil ->
        case extract_block_location(trimmed) do
          {file, line_no} ->
            {severity, msg} = current

            item = %{
              file: normalize_diag_file(file, root_path),
              line: line_no,
              severity: severity,
              message: msg
            }

            do_parse_compiler_blocks(rest, nil, root_path, [item | acc])

          nil ->
            next_current =
              if trimmed == "" or String.starts_with?(line, "=="), do: nil, else: current

            do_parse_compiler_blocks(rest, next_current, root_path, acc)
        end

      nil ->
        do_parse_compiler_blocks(rest, nil, root_path, acc)
    end
  end

  defp extract_block_location(trimmed) do
    cond do
      match = Regex.run(~r/^└─\s+([^:\n]+):(\d+)(?::\d+)?/, trimmed) ->
        [_, file, line_str] = match
        {String.trim(file), String.to_integer(line_str)}

      match = Regex.run(~r/^([^\s:\n][^:\n]*\.(?:ex|exs|erl|hrl)):(\d+)(?::\d+)?/, trimmed) ->
        [_, file, line_str] = match
        {String.trim(file), String.to_integer(line_str)}

      true ->
        nil
    end
  end

  defp normalize_diag_file(nil, _root_path), do: "mix.exs"

  defp normalize_diag_file(file, root_path) when is_binary(file) do
    trimmed = String.trim(file)
    Path.relative_to(trimmed, Path.expand(root_path))
  end

  defp fallback_diag_file("."), do: "mix.exs"
  defp fallback_diag_file(subpath), do: subpath

  defp filter_diagnostics_by_subpath(items, "."), do: items

  defp filter_diagnostics_by_subpath(items, subpath) do
    clean_sub = String.trim_trailing(subpath, "/")

    matching =
      Enum.filter(items, fn item ->
        item.file == clean_sub or String.starts_with?(item.file, clean_sub <> "/")
      end)

    if matching == [], do: items, else: matching
  end

  defp filter_tool_definitions(definitions, :all), do: definitions
  defp filter_tool_definitions(definitions, nil), do: definitions

  defp filter_tool_definitions(definitions, %MapSet{} = allowlist) do
    filter_tool_definitions(definitions, MapSet.to_list(allowlist))
  end

  defp filter_tool_definitions(definitions, allowlist) when is_list(allowlist) do
    allowed = MapSet.new(Enum.map(allowlist, &resolve_tool_alias/1))
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
    val =
      case Map.fetch(map, map_key) do
        {:ok, v} -> v
        :error -> Map.get(map, opt_key)
      end

    case val do
      nil -> opts
      v -> Keyword.put(opts, opt_key, v)
    end
  end

  defp normalize_run_tests_opts(opts) when is_list(opts) do
    case Keyword.fetch(opts, :partition) do
      {:ok, "auto"} -> Keyword.put(opts, :partition, :auto)
      _ -> opts
    end
  end

  defp maybe_put_sub_agent_opt(context, args, string_key, atom_key) do
    cond do
      Map.has_key?(args, string_key) ->
        Map.put(context, atom_key, Map.get(args, string_key))

      Map.has_key?(args, atom_key) ->
        Map.put(context, atom_key, Map.get(args, atom_key))

      true ->
        context
    end
  end

  defp normalize_lsp_action(nil), do: nil

  defp normalize_lsp_action(action) when is_atom(action) do
    action |> Atom.to_string() |> normalize_lsp_action()
  end

  defp normalize_lsp_action(action) when is_binary(action) do
    trimmed = action |> String.trim() |> String.downcase()
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_lsp_action(_other), do: nil

  defp parse_lsp_non_neg_int(nil, default), do: {:ok, default}
  defp parse_lsp_non_neg_int(val, _default) when is_integer(val) and val >= 0, do: {:ok, val}

  defp parse_lsp_non_neg_int(val, _default) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> {:error, :invalid_non_neg_int}
    end
  end

  defp parse_lsp_non_neg_int(_other, _default), do: {:error, :invalid_non_neg_int}

  defp normalize_lsp_server_cmd(nil), do: {:ok, nil}

  defp normalize_lsp_server_cmd([_head | _] = list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
      {:ok, list}
    else
      {:error, :lsp_bad_command}
    end
  end

  defp normalize_lsp_server_cmd([]), do: {:error, :lsp_bad_command}

  defp normalize_lsp_server_cmd(cmd) when is_binary(cmd) do
    trimmed = String.trim(cmd)

    cond do
      trimmed == "" ->
        {:ok, nil}

      File.exists?(trimmed) or System.find_executable(trimmed) != nil ->
        {:ok, [trimmed]}

      true ->
        case OptionParser.split(trimmed) do
          [head | _] = parts when head != "" -> {:ok, parts}
          _ -> {:error, :lsp_bad_command}
        end
    end
  end

  defp normalize_lsp_server_cmd(_other), do: {:error, :lsp_bad_command}

  defp format_lsp_result("hover", nil, _root_path), do: "No hover information found."

  defp format_lsp_result("hover", result, _root_path) do
    text =
      case result do
        %{"contents" => contents} -> extract_hover_contents(contents)
        bin when is_binary(bin) -> String.trim(bin)
        other -> Jason.encode!(other, pretty: true)
      end

    if text == "", do: "No hover information found.", else: text
  end

  defp format_lsp_result(action, result, root_path) when action in ["definition", "references"] do
    locations =
      cond do
        is_nil(result) or result == [] -> []
        is_map(result) -> [result]
        is_list(result) -> Enum.filter(result, &is_map/1)
        true -> []
      end

    noun = if action == "definition", do: "definition(s)", else: "reference(s)"

    if locations == [] do
      "No #{action} found."
    else
      canonical_root = canonical_lsp_root(root_path)

      lines =
        Enum.map(locations, fn loc ->
          uri =
            Map.get(loc, "uri") ||
              Map.get(loc, "targetUri") ||
              get_in(loc, ["location", "uri"])

          range =
            Map.get(loc, "range") ||
              Map.get(loc, "targetSelectionRange") ||
              Map.get(loc, "targetRange") ||
              get_in(loc, ["location", "range"]) ||
              %{}

          start_pos = Map.get(range, "start") || %{}
          l = Map.get(start_pos, "line", 0)
          c = Map.get(start_pos, "character", 0)
          rel_path = lsp_uri_to_rel_path(root_path, canonical_root, uri)
          "#{rel_path}:#{l}:#{c} (L#{l + 1}:C#{c + 1})"
        end)

      "Found #{length(lines)} #{noun}:\n" <> Enum.join(lines, "\n")
    end
  end

  defp format_lsp_result("document_symbols", result, root_path) do
    cond do
      is_nil(result) or result == [] ->
        "No document symbols found."

      is_list(result) ->
        canonical_root = canonical_lsp_root(root_path)
        lines = format_lsp_symbols(result, root_path, canonical_root, 0)

        if lines == [] do
          "No document symbols found."
        else
          "Found #{length(lines)} document symbol(s):\n" <> Enum.join(lines, "\n")
        end

      true ->
        Jason.encode!(result, pretty: true)
    end
  end

  defp extract_hover_contents(val) when is_binary(val), do: String.trim(val)
  defp extract_hover_contents(%{"value" => val}) when is_binary(val), do: String.trim(val)

  defp extract_hover_contents(list) when is_list(list) do
    list
    |> Enum.map(&extract_hover_contents/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp extract_hover_contents(other), do: Jason.encode!(other, pretty: true)

  defp format_lsp_symbols(symbols, root_path, canonical_root, depth) when is_list(symbols) do
    Enum.flat_map(symbols, fn
      %{} = sym ->
        name = Map.get(sym, "name", "<unnamed>")
        kind_label = lsp_symbol_kind_name(Map.get(sym, "kind"))
        indent = String.duplicate("  ", depth)

        loc_str =
          cond do
            is_map(Map.get(sym, "location")) ->
              uri = get_in(sym, ["location", "uri"])
              start_pos = get_in(sym, ["location", "range", "start"]) || %{}
              rel = lsp_uri_to_rel_path(root_path, canonical_root, uri)
              " (#{rel}:#{Map.get(start_pos, "line", 0)}:#{Map.get(start_pos, "character", 0)})"

            is_map(Map.get(sym, "range")) ->
              start_pos = get_in(sym, ["range", "start"]) || %{}
              l = Map.get(start_pos, "line", 0)
              c = Map.get(start_pos, "character", 0)
              " (:#{l}:#{c})"

            true ->
              ""
          end

        children =
          case Map.get(sym, "children") do
            list when is_list(list) ->
              format_lsp_symbols(list, root_path, canonical_root, depth + 1)

            _ ->
              []
          end

        ["#{indent}- [#{kind_label}] #{name}#{loc_str}" | children]

      _other ->
        []
    end)
  end

  defp canonical_lsp_root(root_path) do
    case WorkspacePath.resolve(root_path, ".") do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(root_path)
    end
  end

  defp lsp_uri_to_rel_path(root_path, canonical_root, uri) when is_binary(uri) do
    case LSPClient.resolve_uri_in_root(root_path, uri) do
      {:ok, canonical_file, _} -> Path.relative_to(canonical_file, canonical_root)
      {:error, _} -> uri
    end
  end

  defp lsp_uri_to_rel_path(_root_path, _canonical_root, _other), do: "<unknown>"

  defp lsp_symbol_kind_name(1), do: "file"
  defp lsp_symbol_kind_name(2), do: "module"
  defp lsp_symbol_kind_name(3), do: "namespace"
  defp lsp_symbol_kind_name(4), do: "package"
  defp lsp_symbol_kind_name(5), do: "class"
  defp lsp_symbol_kind_name(6), do: "method"
  defp lsp_symbol_kind_name(7), do: "property"
  defp lsp_symbol_kind_name(8), do: "field"
  defp lsp_symbol_kind_name(9), do: "constructor"
  defp lsp_symbol_kind_name(10), do: "enum"
  defp lsp_symbol_kind_name(11), do: "interface"
  defp lsp_symbol_kind_name(12), do: "function"
  defp lsp_symbol_kind_name(13), do: "variable"
  defp lsp_symbol_kind_name(14), do: "constant"
  defp lsp_symbol_kind_name(15), do: "string"
  defp lsp_symbol_kind_name(16), do: "number"
  defp lsp_symbol_kind_name(17), do: "boolean"
  defp lsp_symbol_kind_name(18), do: "array"
  defp lsp_symbol_kind_name(19), do: "object"
  defp lsp_symbol_kind_name(20), do: "key"
  defp lsp_symbol_kind_name(21), do: "null"
  defp lsp_symbol_kind_name(22), do: "enum_member"
  defp lsp_symbol_kind_name(23), do: "struct"
  defp lsp_symbol_kind_name(24), do: "event"
  defp lsp_symbol_kind_name(25), do: "operator"
  defp lsp_symbol_kind_name(26), do: "type_parameter"
  defp lsp_symbol_kind_name(kind) when is_integer(kind), do: "kind_#{kind}"
  defp lsp_symbol_kind_name(_), do: "symbol"
end
