defmodule IexCode.LLM.CodingCompactionAndRulesTest do
  use ExUnit.Case, async: true

  alias IexCode.LLM.{Anthropic, ContextCompactor, Gemini, OpenAI, RequestPreparation}
  alias IexCode.LLM.SystemPromptBuilder
  alias IexCode.Settings.AppSettings

  describe "cross-provider protocol-safe exchange grouping" do
    test "restore_exchange_boundary/2 preserves Anthropic tool_use + tool_result content-block exchanges" do
      dropped = [
        %{role: "user", content: "Inspect configuration"},
        %{
          role: "assistant",
          content: [
            %{type: "thinking", thinking: "Need to inspect both config files."},
            %{
              type: "tool_use",
              id: "toolu_1",
              name: "read_file",
              input: %{path: "config/dev.exs"}
            },
            %{
              type: "tool_use",
              id: "toolu_2",
              name: "read_file",
              input: %{path: "config/runtime.exs"}
            }
          ]
        },
        %{
          role: "user",
          content: [
            %{type: "tool_result", tool_use_id: "toolu_1", content: "import Config\n# dev"}
          ]
        }
      ]

      kept = [
        %{
          role: "user",
          content: [
            %{type: "tool_result", tool_use_id: "toolu_2", content: "import Config\n# runtime"}
          ]
        },
        %{role: "assistant", content: "Both configs look valid."}
      ]

      restored = ContextCompactor.restore_exchange_boundary(dropped, kept)
      assert length(restored) == 4
      assert Enum.at(restored, 0) == Enum.at(dropped, 1)
      assert Enum.at(restored, 1) == Enum.at(dropped, 2)
      assert Enum.take(restored, -2) == kept
    end

    test "restore_exchange_boundary/2 preserves Gemini functionCall + functionResponse exchanges" do
      dropped = [
        %{"role" => "user", "parts" => [%{"text" => "Run test suite"}]},
        %{
          "role" => "model",
          "parts" => [
            %{"thought" => true, "text" => "Running mix test"},
            %{
              "functionCall" => %{"name" => "run_tests", "args" => %{"path" => "test/a_test.exs"}}
            },
            %{
              "functionCall" => %{"name" => "run_tests", "args" => %{"path" => "test/b_test.exs"}}
            }
          ]
        },
        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => "run_tests",
                "response" => %{"result" => "1 test, 0 failures"}
              }
            }
          ]
        }
      ]

      kept = [
        %{
          "role" => "user",
          "parts" => [
            %{
              "functionResponse" => %{
                "name" => "run_tests",
                "response" => %{"result" => "2 tests, 0 failures"}
              }
            }
          ]
        },
        %{"role" => "model", "parts" => [%{"text" => "All tests passed."}]}
      ]

      restored = ContextCompactor.restore_exchange_boundary(dropped, kept)
      assert length(restored) == 4
      assert Enum.at(restored, 0) == Enum.at(dropped, 1)
      assert Enum.at(restored, 1) == Enum.at(dropped, 2)
      assert Enum.take(restored, -2) == kept
    end

    test "restore_exchange_boundary/2 also supports Gemini functionCall/functionResponse in content lists" do
      dropped = [
        %{"role" => "user", "content" => "Check git status"},
        %{
          "role" => "assistant",
          "content" => [%{"functionCall" => %{"name" => "git_status", "args" => %{}}}]
        }
      ]

      kept = [
        %{
          "role" => "user",
          "content" => [
            %{
              "functionResponse" => %{
                "name" => "git_status",
                "response" => %{"result" => "clean"}
              }
            }
          ]
        },
        %{"role" => "assistant", "content" => "Working tree is clean."}
      ]

      assert ContextCompactor.restore_exchange_boundary(dropped, kept) ==
               [Enum.at(dropped, 1) | kept]
    end

    test "restore_exchange_boundary/2 does not pull unrelated user prompt onto an unrestorable orphan reply" do
      dropped = [%{role: "user", content: "Unrelated earlier user message"}]

      kept = [
        %{
          role: "user",
          content: [%{type: "tool_result", tool_use_id: "orphan_id", content: "orphan"}]
        }
      ]

      assert ContextCompactor.restore_exchange_boundary(dropped, kept) == kept
    end

    for strategy <- ["sliding_window", "rolling_summary", "token_compaction"] do
      @strategy strategy
      test "compact/3 (#{strategy}) never splits Anthropic content-block tool exchanges" do
        messages = [
          %{"role" => "user", "content" => "Root objective"},
          %{"role" => "assistant", "content" => String.duplicate("Earlier discussion ", 120)},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "tu_1",
                "name" => "read_file",
                "input" => %{"path" => "lib/app.ex"}
              }
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "tu_1",
                "content" => "defmodule App do\nend"
              }
            ]
          }
        ]

        compacted =
          ContextCompactor.compact(messages, %{
            context_window_tokens: 120,
            context_prune_threshold_percent: 10,
            context_compaction_strategy: @strategy,
            keep_recent_turns: 1
          })

        assert hd(compacted) == hd(messages)
        assert Enum.take(compacted, -2) == Enum.take(messages, -2)
      end

      test "RequestPreparation.prepare/4 (#{strategy}) removes whole Anthropic tool_use/tool_result exchanges atomically" do
        messages = [
          %{role: "user", content: "Original objective", budget_mandatory: true},
          %{
            role: "assistant",
            content: [
              %{
                "type" => "tool_use",
                "id" => "tu_old",
                "name" => "read_file",
                "input" => %{"path" => "lib/old.ex"}
              }
            ]
          },
          %{
            role: "user",
            content: [
              %{
                "type" => "tool_result",
                "tool_use_id" => "tu_old",
                "content" => String.duplicate("verbose line\n", 400)
              }
            ]
          },
          %{
            role: "assistant",
            content: [
              %{
                "type" => "tool_use",
                "id" => "tu_keep",
                "name" => "read_file",
                "input" => %{"path" => "lib/keep.ex"}
              }
            ]
          },
          %{
            role: "user",
            content: [
              %{
                "type" => "tool_result",
                "tool_use_id" => "tu_keep",
                "content" => "small output",
                "budget_mandatory" => true
              }
            ],
            budget_mandatory: true
          },
          %{role: "user", content: "Current objective", budget_objective: true}
        ]

        opts = [
          model: "claude-3-5-sonnet",
          max_tokens: 100,
          reasoning_effort: "none",
          budget_settings: %{
            context_window_tokens: 900,
            context_compaction_strategy: @strategy,
            keep_recent_turns: 2
          }
        ]

        assert {:ok, prepared} =
                 RequestPreparation.prepare(Anthropic, messages, "System rules", opts)

        tool_uses =
          for m <- prepared.messages,
              is_list(Map.get(m, :content)),
              b <- m.content,
              b["type"] == "tool_use",
              do: b["id"]

        tool_results =
          for m <- prepared.messages,
              is_list(Map.get(m, :content)),
              b <- m.content,
              b["type"] == "tool_result",
              do: b["tool_use_id"]

        assert tool_uses == tool_results
        assert "tu_keep" in tool_uses
      end

      test "RequestPreparation.prepare/4 (#{strategy}) removes whole Gemini functionCall/functionResponse exchanges atomically" do
        messages = [
          %{"role" => "user", "content" => "Original objective", "budget_mandatory" => true},
          %{
            "role" => "model",
            "parts" => [
              %{"functionCall" => %{"name" => "read_old", "args" => %{"path" => "lib/old.ex"}}}
            ]
          },
          %{
            "role" => "user",
            "parts" => [
              %{
                "functionResponse" => %{
                  "name" => "read_old",
                  "response" => %{"result" => String.duplicate("verbose payload ", 400)}
                }
              }
            ]
          },
          %{
            "role" => "model",
            "parts" => [
              %{"functionCall" => %{"name" => "read_keep", "args" => %{"path" => "lib/keep.ex"}}}
            ]
          },
          %{
            "role" => "user",
            "budget_mandatory" => true,
            "parts" => [
              %{
                "functionResponse" => %{
                  "name" => "read_keep",
                  "response" => %{"result" => "kept result"}
                }
              }
            ]
          },
          %{"role" => "user", "content" => "Finish fix", "budget_objective" => true}
        ]

        opts = [
          model: "gemini-2.5-pro",
          max_tokens: 100,
          reasoning_effort: "none",
          budget_settings: %{
            context_window_tokens: 900,
            context_compaction_strategy: @strategy,
            keep_recent_turns: 2
          }
        ]

        assert {:ok, prepared} =
                 RequestPreparation.prepare(Gemini, messages, "System rules", opts)

        calls =
          for m <- prepared.messages,
              is_list(m["parts"]),
              p <- m["parts"],
              is_map(p["functionCall"]),
              do: p["functionCall"]["name"]

        responses =
          for m <- prepared.messages,
              is_list(m["parts"]),
              p <- m["parts"],
              is_map(p["functionResponse"]),
              do: p["functionResponse"]["name"]

        assert calls == responses
        assert "read_keep" in calls
      end
    end

    test "RequestPreparation.prepare/4 protects user objective when trailing message is a user tool_result" do
      messages = [
        %{role: "user", content: "Fix authentication bug"},
        %{
          role: "assistant",
          content: [
            %{"type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => %{}}
          ]
        },
        %{
          role: "user",
          content: [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tu_1",
              "content" => String.duplicate("huge dump ", 500)
            }
          ]
        }
      ]

      opts = [
        model: "claude-3-5-sonnet",
        max_tokens: 100,
        reasoning_effort: "none",
        budget_settings: %{
          context_window_tokens: 550,
          context_compaction_strategy: "sliding_window"
        }
      ]

      assert {:ok, prepared} = RequestPreparation.prepare(Anthropic, messages, "", opts)
      assert hd(prepared.messages).content == "Fix authentication bug"
    end

    test "RequestPreparation.prepare/4 (OpenAI) injects Working memory in rolling_summary without splitting tool_calls" do
      messages = [
        %{role: "user", content: "Original objective", budget_mandatory: true},
        %{
          role: "assistant",
          content: "Patching router",
          tool_calls: [
            %{id: "call_old", name: "edit_file", args: %{"path" => "lib/router.ex"}}
          ]
        },
        %{
          role: "tool",
          tool_call_id: "call_old",
          content:
            "Exit Code 1\ndiff --git a/lib/router.ex b/lib/router.ex\n** (CompileError) lib/router.ex:15: syntax error\n" <>
              String.duplicate("verbose line\n", 300)
        },
        %{
          role: "assistant",
          content: "Reading router",
          budget_mandatory: true,
          tool_calls: [%{id: "call_keep", name: "read_file", args: %{"path" => "lib/router.ex"}}]
        },
        %{role: "tool", tool_call_id: "call_keep", content: "defmodule Router, do: nil"},
        %{role: "user", content: "Finish router fix", budget_objective: true}
      ]

      opts = [
        model: "gpt-4o",
        max_tokens: 100,
        budget_settings: %{
          context_window_tokens: 900,
          context_compaction_strategy: "rolling_summary"
        }
      ]

      assert {:ok, prepared} = RequestPreparation.prepare(OpenAI, messages, "Instructions", opts)

      calls = for %{tool_calls: tcs} <- prepared.messages, tc <- tcs, do: tc.id
      replies = for %{role: "tool", tool_call_id: id} <- prepared.messages, do: id
      assert calls == ["call_keep"]
      assert replies == ["call_keep"]

      summary_msg =
        Enum.find(prepared.messages, fn m ->
          is_binary(m[:content]) and
            String.starts_with?(m.content, "Summary of earlier conversation history:")
        end)

      assert summary_msg != nil
      assert summary_msg.content =~ "Working memory:"
      assert summary_msg.content =~ "lib/router.ex"
      assert summary_msg.content =~ "Exit Code 1"
    end
  end

  describe "coding working-memory ledger in rolling_summary" do
    test "preserves legacy summary bullets AND appends structured Working memory section" do
      messages = [
        %{role: "user", content: "Fix parser crash and commit"},
        %{
          role: "assistant",
          content: "Inspecting parser implementation",
          tool_calls: [
            %{id: "c1", name: "read_file", args: %{"path" => "lib/my_app/parser.ex"}}
          ]
        },
        %{
          role: "tool",
          tool_call_id: "c1",
          content: "Showing lines 1 to 40 of lib/my_app/parser.ex"
        },
        %{
          role: "assistant",
          content: "Patching parser clause",
          tool_calls: [
            %{id: "c2", name: "edit_file", args: %{"path" => "lib/my_app/parser.ex"}}
          ]
        },
        %{
          role: "tool",
          tool_call_id: "c2",
          content:
            "diff --git a/lib/my_app/parser.ex b/lib/my_app/parser.ex\n--- a/lib/my_app/parser.ex\n+++ b/lib/my_app/parser.ex\n@@ -12,3 +12,4 @@\n+  def parse(nil), do: {:ok, nil}"
        },
        %{
          role: "tool",
          tool_call_id: "c3",
          content:
            "Exit Code 2\n** (ExUnit.AssertionError) Assertion with == failed\n    (my_app 0.1.0) lib/my_app/parser.ex:19: MyApp.Parser.parse/1\n    test/my_app/parser_test.exs:44: (test)"
        },
        %{
          role: "tool",
          tool_call_id: "c4",
          content: "[main 9f8e7d6] Handle nil input in parser\n 1 file changed, 2 insertions(+)"
        },
        %{role: "user", content: "Re-run tests now"},
        %{role: "assistant", content: "Running mix test"}
      ]

      settings = %AppSettings{
        context_window_tokens: 1_200,
        context_prune_threshold_percent: 50,
        context_compaction_strategy: "rolling_summary",
        keep_recent_turns: 2
      }

      # Ensure we exceed threshold by adding padding on an older turn if needed
      padded_messages =
        List.insert_at(messages, 1, %{
          role: "user",
          content: "Context details: " <> String.duplicate("spec ", 500)
        })

      compacted = ContextCompactor.compact(padded_messages, settings)
      summary = Enum.at(compacted, 1)

      assert summary.role == "system"
      assert summary.content =~ "Summary of earlier conversation history:"
      assert summary.content =~ "- User requested:"
      assert summary.content =~ "- Assistant planned:"
      assert summary.content =~ "- Tool executed:"
      assert summary.content =~ "Working memory:"
      assert summary.content =~ "- Files:"
      assert summary.content =~ "lib/my_app/parser.ex"
      assert summary.content =~ "test/my_app/parser_test.exs"
      assert summary.content =~ "- Patches/Commits:"
      assert summary.content =~ "9f8e7d6"
      assert summary.content =~ "- Failures:"
      assert summary.content =~ "Exit Code 2"
      assert summary.content =~ "lib/my_app/parser.ex:19"
      assert summary.content =~ "test/my_app/parser_test.exs:44"
      assert ContextCompactor.estimate_tokens(compacted) <= 600
    end

    test "strictly bounds rolling_summary + Working memory to available_tokens across tight budgets" do
      coding_turns =
        Enum.flat_map(1..40, fn i ->
          [
            %{
              "role" => "assistant",
              "content" => "Patching module #{i}",
              "tool_calls" => [
                %{
                  "id" => "tc_#{i}",
                  "name" => "edit_file",
                  "args" => %{"path" => "lib/mod_#{i}.ex"}
                }
              ]
            },
            %{
              "role" => "tool",
              "tool_call_id" => "tc_#{i}",
              "content" =>
                "Exit Code 1\ndiff --git a/lib/mod_#{i}.ex b/lib/mod_#{i}.ex\n" <>
                  "** (CompileError) lib/mod_#{i}.ex:#{i + 10}: undefined value\n" <>
                  "    test/mod_#{i}_test.exs:#{i + 20}: (test)"
            }
          ]
        end)

      messages =
        [%{"role" => "user", "content" => "Root coding goal"} | coding_turns] ++
          [
            %{"role" => "user", "content" => "Latest instruction"},
            %{"role" => "assistant", "content" => "Latest reply"}
          ]

      for window <- [240, 320, 500, 900, 1_600] do
        settings = %AppSettings{
          context_window_tokens: window,
          context_prune_threshold_percent: 50,
          context_compaction_strategy: "rolling_summary",
          keep_recent_turns: 2
        }

        trigger_budget = div(window, 2)
        compacted = ContextCompactor.compact(messages, settings)

        assert ContextCompactor.estimate_tokens(compacted) <= trigger_budget,
               "Expected compacted tokens <= #{trigger_budget} for window #{window}"

        summary = Enum.at(compacted, 1)

        if summary["role"] == "system" do
          assert String.valid?(summary["content"])
          refute String.ends_with?(String.trim(summary["content"]), "Working memory:")
        end
      end
    end
  end

  describe "smart output pruning for diffs and Elixir stacktraces" do
    test "preserves diff --git, ---, +++, and @@ headers across multi-file diffs" do
      multi_file_diff =
        [
          "diff --git a/lib/alpha.ex b/lib/alpha.ex",
          "index 1111111..2222222 100644",
          "--- a/lib/alpha.ex",
          "+++ b/lib/alpha.ex",
          "@@ -1,10 +1,12 @@",
          Enum.map_join(1..35, "\n", &"+  alpha_line_#{&1} = :ok"),
          "diff --git a/lib/beta.ex b/lib/beta.ex",
          "index 3333333..4444444 100644",
          "--- a/lib/beta.ex",
          "+++ b/lib/beta.ex",
          "@@ -40,6 +40,9 @@",
          Enum.map_join(1..35, "\n", &"-  beta_old_line_#{&1}()"),
          "diff --git a/test/beta_test.exs b/test/beta_test.exs",
          "--- a/test/beta_test.exs",
          "+++ b/test/beta_test.exs",
          "@@ -10,4 +10,8 @@",
          Enum.map_join(1..30, "\n", &"+  assert beta_check(#{&1}) == :ok")
        ]
        |> Enum.join("\n")

      compacted =
        ContextCompactor.compact_tool_message(%{role: "tool", content: multi_file_diff}).content

      assert byte_size(compacted) < byte_size(multi_file_diff)
      assert compacted =~ "diff --git a/lib/alpha.ex b/lib/alpha.ex"
      assert compacted =~ "diff --git a/lib/beta.ex b/lib/beta.ex"
      assert compacted =~ "--- a/lib/beta.ex"
      assert compacted =~ "+++ b/lib/beta.ex"
      assert compacted =~ "@@ -40,6 +40,9 @@"
      assert compacted =~ "diff --git a/test/beta_test.exs b/test/beta_test.exs"
      assert compacted =~ "@@ -10,4 +10,8 @@"
      assert compacted =~ "compacted"
    end

    test "preserves ** (...) exceptions and lib/...:line + test/...:line frames in middle of stacktrace" do
      verbose_test_failure =
        [
          "Exit Code 2",
          Enum.map_join(1..30, "\n", &"Compiling file_#{&1}.ex..."),
          "  1) test handles edge case (IexCode.SampleTest)",
          "     test/iex_code/sample_test.exs:88",
          "     ** (FunctionClauseError) no function clause matching in IexCode.Sample.run/2",
          Enum.map_join(
            1..25,
            "\n",
            &"     verbose inspected payload line #{&1}: %{data: :blob}"
          ),
          "     stacktrace:",
          "       (iex_code 0.1.0) lib/iex_code/sample.ex:142: IexCode.Sample.run/2",
          "       (iex_code 0.1.0) lib/iex_code/runner.ex:57: IexCode.Runner.exec/1",
          "       test/iex_code/sample_test.exs:89: (test)",
          Enum.map_join(1..25, "\n", &".......dot progress line #{&1}......."),
          "Finished in 1.2 seconds",
          "42 tests, 1 failure"
        ]
        |> Enum.join("\n")

      compacted =
        ContextCompactor.compact_tool_message(%{role: "tool", content: verbose_test_failure}).content

      assert byte_size(compacted) < byte_size(verbose_test_failure)
      assert compacted =~ "Exit Code 2"
      assert compacted =~ "** (FunctionClauseError) no function clause matching"
      assert compacted =~ "lib/iex_code/sample.ex:142"
      assert compacted =~ "lib/iex_code/runner.ex:57"
      assert compacted =~ "test/iex_code/sample_test.exs:88"
      assert compacted =~ "test/iex_code/sample_test.exs:89"
      assert compacted =~ "42 tests, 1 failure"
      assert compacted =~ "compacted"
    end

    test "compacts bulky tool_result and functionResponse blocks inside user messages" do
      bulky =
        "Exit Code 1\n" <>
          Enum.map_join(1..60, "\n", &"verbose output line #{&1} with padding text") <>
          "\n** (RuntimeError) boom\n    lib/foo.ex:12: Foo.bar/0\nDone"

      anthropic_msg = %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "tu_1", "content" => bulky}
        ]
      }

      compacted_anth = ContextCompactor.compact_tool_message(anthropic_msg)
      anth_text = hd(compacted_anth["content"])["content"]
      assert byte_size(anth_text) < byte_size(bulky)
      assert anth_text =~ "** (RuntimeError) boom"
      assert anth_text =~ "lib/foo.ex:12"

      gemini_msg = %{
        "role" => "user",
        "parts" => [
          %{
            "functionResponse" => %{
              "name" => "run_cmd",
              "response" => %{"result" => bulky}
            }
          }
        ]
      }

      compacted_gem = ContextCompactor.compact_tool_message(gemini_msg)
      gem_text = hd(compacted_gem["parts"])["functionResponse"]["response"]["result"]
      assert byte_size(gem_text) < byte_size(bulky)
      assert gem_text =~ "** (RuntimeError) boom"
      assert gem_text =~ "lib/foo.ex:12"
    end
  end

  describe "effective_window_tokens/2" do
    test "returns explicit integer or @default_window_tokens (128_000) when :auto is omitted" do
      assert ContextCompactor.effective_window_tokens(nil, "gemini-2.5-pro") == 128_000
      assert ContextCompactor.effective_window_tokens(%{}, "gemini-2.5-pro") == 128_000

      assert ContextCompactor.effective_window_tokens(%AppSettings{}, "claude-sonnet-4-5") ==
               128_000

      assert ContextCompactor.effective_window_tokens(
               %AppSettings{context_window_tokens: 32_000},
               "gpt-5"
             ) == 32_000

      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: 64_000},
               "gemini-3-pro"
             ) == 64_000
    end

    test "resolves model-aware windows via Capabilities when :auto or auto_model_window: true" do
      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: :auto},
               "gemini-2.5-pro"
             ) == 1_000_000

      assert ContextCompactor.effective_window_tokens(
               %{"context_window_tokens" => "auto"},
               "claude-sonnet-4-5"
             ) == 200_000

      assert ContextCompactor.effective_window_tokens(
               %{auto_model_window: true},
               "gpt-5-high"
             ) == 400_000

      assert ContextCompactor.effective_window_tokens(
               %{auto_model_window: true},
               "codex-mini"
             ) == 400_000

      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: :auto},
               "o3-mini"
             ) == 200_000

      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: :auto, provider: "ollama"},
               "llama3"
             ) == 16_384

      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: :auto},
               "deepseek-r1:14b"
             ) == 32_768

      assert ContextCompactor.effective_window_tokens(
               %{context_window_tokens: :auto},
               "gpt-4o"
             ) == 128_000
    end
  end

  describe "SystemPromptBuilder hierarchical & multi-file repo rules" do
    setup do
      base_tmp =
        Path.join(
          System.tmp_dir!(),
          "iex_code_rules_suite_#{System.unique_integer([:positive])}"
        )

      root = Path.join(base_tmp, "workspace")
      outside = Path.join(base_tmp, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)

      on_exit(fn -> File.rm_rf(base_tmp) end)
      {:ok, root: root, outside: outside}
    end

    test "discovers root rule files in deterministic order and deduplicates identical content", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, ".iexcode"))
      File.write!(Path.join(root, "AGENTS.md"), "Rule 1: Use Req for HTTP.")
      # Identical content to AGENTS.md -> must be deduplicated
      File.write!(Path.join(root, "CLAUDE.md"), "  Rule 1: Use Req for HTTP.\n")
      File.write!(Path.join(root, "CODEX.md"), "Rule 2: Run mix format.")
      File.write!(Path.join(root, ".iexcode/instructions.md"), "Rule 3: Keep functions small.")

      prompt = SystemPromptBuilder.build("Base role", root, %AppSettings{})

      assert prompt =~ "## Project Workspace Rules (AGENTS.md)\nRule 1: Use Req for HTTP."
      refute prompt =~ "## Project Workspace Rules (CLAUDE.md)"
      assert prompt =~ "## Project Workspace Rules (CODEX.md)\nRule 2: Run mix format."

      assert prompt =~
               "## Project Workspace Rules (.iexcode/instructions.md)\nRule 3: Keep functions small."

      {agents_pos, _} = :binary.match(prompt, "## Project Workspace Rules (AGENTS.md)")
      {codex_pos, _} = :binary.match(prompt, "## Project Workspace Rules (CODEX.md)")

      {inst_pos, _} =
        :binary.match(prompt, "## Project Workspace Rules (.iexcode/instructions.md)")

      {sec_pos, _} = :binary.match(prompt, "## Security & Execution Boundary")

      assert agents_pos < codex_pos
      assert codex_pos < inst_pos
      assert inst_pos < sec_pos
    end

    test "discovers nested AGENTS.md from root down to active subdirectories via build/4", %{
      root: root
    } do
      File.write!(Path.join(root, "AGENTS.md"), "Root workspace rule.")

      apps_dir = Path.join(root, "apps")
      billing_dir = Path.join(root, "apps/billing")
      billing_lib = Path.join(root, "apps/billing/lib")
      other_dir = Path.join(root, "apps/other")

      File.mkdir_p!(billing_lib)
      File.mkdir_p!(other_dir)

      File.write!(Path.join(apps_dir, "AGENTS.md"), "Umbrella apps rule.")
      File.write!(Path.join(billing_dir, "AGENTS.md"), "Billing domain rule.")
      File.write!(Path.join(other_dir, "AGENTS.md"), "Unrelated sibling app rule.")

      # build/3 without active_paths only reads root rules
      root_only_prompt = SystemPromptBuilder.build("Base role", root, %AppSettings{})
      assert root_only_prompt =~ "## Project Workspace Rules (AGENTS.md)"
      refute root_only_prompt =~ "apps/AGENTS.md"
      refute root_only_prompt =~ "apps/billing/AGENTS.md"

      # build/4 with active_paths walks root -> apps -> apps/billing -> apps/billing/lib
      scoped_prompt =
        SystemPromptBuilder.build("Base role", root, %AppSettings{},
          active_paths: ["apps/billing/lib/invoice.ex"]
        )

      assert scoped_prompt =~ "## Project Workspace Rules (AGENTS.md)\nRoot workspace rule."
      assert scoped_prompt =~ "## Project Workspace Rules (apps/AGENTS.md)\nUmbrella apps rule."

      assert scoped_prompt =~
               "## Project Workspace Rules (apps/billing/AGENTS.md)\nBilling domain rule."

      refute scoped_prompt =~ "apps/other/AGENTS.md"
      refute scoped_prompt =~ "Unrelated sibling app rule."

      {root_pos, _} = :binary.match(scoped_prompt, "## Project Workspace Rules (AGENTS.md)")
      {apps_pos, _} = :binary.match(scoped_prompt, "## Project Workspace Rules (apps/AGENTS.md)")

      {billing_pos, _} =
        :binary.match(scoped_prompt, "## Project Workspace Rules (apps/billing/AGENTS.md)")

      assert root_pos < apps_pos
      assert apps_pos < billing_pos
    end

    test "enforces workspace path and symlink containment inside root", %{
      root: root,
      outside: outside
    } do
      secret_path = Path.join(outside, "secret_rules.md")
      File.write!(secret_path, "TOP SECRET OUTSIDE WORKSPACE DATA")

      # Symlink AGENTS.md to outside file
      File.ln_s!(secret_path, Path.join(root, "AGENTS.md"))

      # Symlink nested directory outside workspace
      File.ln_s!(outside, Path.join(root, "escaped_dir"))
      File.write!(Path.join(outside, "AGENTS.md"), "ESCAPED DIR AGENTS RULE")

      # Legitimate in-workspace CLAUDE.md
      File.write!(Path.join(root, "CLAUDE.md"), "Safe inside workspace rule.")

      prompt =
        SystemPromptBuilder.build("Base role", root, %AppSettings{},
          active_paths: [
            "escaped_dir/file.ex",
            "../outside/secret_rules.md",
            secret_path
          ]
        )

      refute prompt =~ "TOP SECRET OUTSIDE WORKSPACE DATA"
      refute prompt =~ "ESCAPED DIR AGENTS RULE"
      refute prompt =~ "## Project Workspace Rules (AGENTS.md)"
      assert prompt =~ "## Project Workspace Rules (CLAUDE.md)\nSafe inside workspace rule."
    end

    test "deduplicates in-workspace symlinks pointing to the same canonical rule file", %{
      root: root
    } do
      File.write!(Path.join(root, "AGENTS.md"), "Canonical shared instructions.")
      File.ln_s!("AGENTS.md", Path.join(root, "CLAUDE.md"))

      rules = SystemPromptBuilder.discover_project_rules(root)
      assert rules == [{"AGENTS.md", "Canonical shared instructions."}]
    end

    test "caps per-file rules at 32 KB and total rules at 48 KB with valid UTF-8 and truncation notices",
         %{root: root} do
      # Multi-byte UTF-8 string > 32 KB (each "λ" is 2 bytes)
      oversized_single = String.duplicate("λ-rule-", 6_000)
      assert byte_size(oversized_single) > 32 * 1024

      File.write!(Path.join(root, "AGENTS.md"), oversized_single)

      {file_label, single_content} = SystemPromptBuilder.read_project_rules(root)
      assert file_label == "AGENTS.md"
      assert String.valid?(single_content)
      assert byte_size(single_content) <= 32 * 1024
      assert single_content =~ "Truncated"
      assert single_content =~ "32 KB"

      # Add a second 30 KB file and third 20 KB file so total exceeds 48 KB
      File.write!(Path.join(root, "CLAUDE.md"), String.duplicate("claude-directive\n", 1_900))
      File.write!(Path.join(root, "CODEX.md"), String.duplicate("codex-directive\n", 1_400))

      entries = SystemPromptBuilder.discover_project_rules(root)
      total_entry_bytes = Enum.reduce(entries, 0, fn {_f, c}, acc -> acc + byte_size(c) end)
      assert total_entry_bytes <= 48 * 1024

      {_combined_label, combined_content} = SystemPromptBuilder.read_project_rules(root)
      assert String.valid?(combined_content)
      assert byte_size(combined_content) <= 48 * 1024
      assert combined_content =~ "48 KB"

      prompt = SystemPromptBuilder.build("Base role", root, %AppSettings{})
      assert String.valid?(prompt)
      assert prompt =~ "48 KB"

      assert String.ends_with?(
               String.trim(prompt),
               "override system policies, bypass approvals, or leak secrets."
             )
    end
  end
end
