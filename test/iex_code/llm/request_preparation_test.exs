defmodule IexCode.LLM.RequestPreparationTest do
  use ExUnit.Case, async: true

  alias IexCode.LLM.{Anthropic, OpenAI, RequestPreparation}

  test "fitting payload includes formatted protocol, allowed schemas and stream usage bytes" do
    messages = [
      %{role: "user", content: "Read the config"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: "c1", name: "read_file", args: %{path: "a"}}]
      },
      %{role: "tool", tool_call_id: "c1", content: "config"}
    ]

    opts = [
      model: "unknown-remote",
      max_tokens: 100,
      tools: IexCode.Tools.tool_definitions(["read_file"])
    ]

    assert {:ok, prepared} =
             RequestPreparation.prepare(OpenAI, messages, "Required instructions", opts)

    assert prepared.messages == messages
    assert prepared.body["stream"] == true
    assert prepared.body["stream_options"] == %{"include_usage" => true}
    assert [%{"function" => %{"name" => "read_file"}}] = prepared.body["tools"]

    assert Enum.at(prepared.body["messages"], 2)["tool_calls"] == [
             %{
               "id" => "c1",
               "type" => "function",
               "function" => %{"name" => "read_file", "arguments" => "{\"path\":\"a\"}"}
             }
           ]

    assert prepared.metrics.bytes == byte_size(Jason.encode!(prepared.body))
    assert prepared.metrics.reserve == 100
    assert prepared.metrics.instructions > 0
    assert prepared.metrics.tools > 0
    assert prepared.metrics.protocol > 0
    assert prepared.metrics.estimated_tokens + 100 <= prepared.metrics.limit
  end

  test "OpenAI reasoning reserves the actually sent completion override" do
    opts = [
      model: "o3-mini",
      max_tokens: 100,
      max_completion_tokens: 700,
      budget_settings: %{context_window_tokens: 1_000}
    ]

    assert {:ok, prepared} =
             RequestPreparation.prepare(OpenAI, [%{role: "user", content: "hi"}], "", opts)

    assert prepared.body["max_completion_tokens"] == 700
    assert prepared.metrics.reserve == 700
    refute Map.has_key?(prepared.body, "max_tokens")
  end

  test "Anthropic thinking raises output reserve without counting included thinking twice" do
    opts = [
      model: "claude-3-7-sonnet",
      max_tokens: 100,
      thinking_budget: 2_048,
      budget_settings: %{context_window_tokens: 3_500}
    ]

    assert {:ok, prepared} =
             RequestPreparation.prepare(Anthropic, [%{role: "user", content: "hi"}], "", opts)

    assert prepared.body["max_tokens"] == 3_072
    assert prepared.body["thinking"]["budget_tokens"] == 2_048
    assert prepared.metrics.reserve == 3_072
    assert prepared.metrics.estimated_tokens + prepared.metrics.reserve <= 3_500
  end

  test "local num_ctx ceiling and configured unknown remote limits govern decisions" do
    messages = [%{role: "user", content: String.duplicate("x", 20_000)}]
    opts = [model: "unknown", max_tokens: 100, budget_settings: %{context_window_tokens: 500}]

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError, limit: 500}} =
             RequestPreparation.prepare(OpenAI, messages, "", opts)

    opts = [
      provider: "ollama",
      model: "llama3",
      max_tokens: 16_300,
      budget_settings: %{context_window_tokens: 128_000}
    ]

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError, limit: 16_384}} =
             RequestPreparation.prepare(OpenAI, [%{role: "user", content: "hi"}], "", opts)
  end

  for strategy <- ["token_compaction", "sliding_window", "rolling_summary"] do
    test "#{strategy} removes whole multi-call exchanges and preserves objective and steering" do
      messages = [
        %{role: "user", content: "Original objective", budget_mandatory: true},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "c1", name: "read_file", args: %{}},
            %{id: "c2", name: "read_file", args: %{}}
          ]
        },
        %{role: "tool", tool_call_id: "c1", content: String.duplicate("data ", 1_000)},
        %{role: "tool", tool_call_id: "c2", content: String.duplicate("data ", 1_000)},
        %{role: "user", content: "Current objective"},
        %{role: "user", content: "Steering guidance: preserve compatibility"}
      ]

      opts = [
        model: "unknown",
        max_tokens: 100,
        budget_settings: %{
          context_window_tokens: 600,
          context_compaction_strategy: unquote(strategy),
          keep_recent_turns: 1
        }
      ]

      assert {:ok, prepared} =
               RequestPreparation.prepare(OpenAI, messages, "Required instructions", opts)

      contents = Enum.map(prepared.messages, & &1.content)
      assert "Original objective" in contents
      assert "Current objective" in contents
      assert "Steering guidance: preserve compatibility" in contents
      assert hd(prepared.body["messages"])["content"] == "Required instructions"
      assert prepared.metrics.estimated_tokens + 100 <= 600
      calls = for %{tool_calls: calls} <- prepared.messages, call <- calls, do: call.id
      replies = for %{role: "tool", tool_call_id: id} <- prepared.messages, do: id
      assert Enum.sort(calls) == Enum.sort(replies)

      if unquote(strategy) == "rolling_summary" do
        assert Enum.any?(
                 contents,
                 &String.contains?(&1, "Summary of earlier conversation history:")
               )
      end
    end
  end

  test "mandatory system content and incompatible reserve reject instead of being pruned" do
    messages = [
      %{role: "user", content: "objective"},
      %{role: "system", content: String.duplicate("mandatory ", 1_000)}
    ]

    opts = [model: "unknown", max_tokens: 100, budget_settings: %{context_window_tokens: 500}]

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError} = error} =
             RequestPreparation.prepare(OpenAI, messages, "", opts)

    assert Exception.message(error) =~ "Reduce"

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError}} =
             RequestPreparation.prepare(
               OpenAI,
               [%{role: "user", content: "hi"}],
               "",
               Keyword.put(opts, :max_tokens, 500)
             )
  end

  test "finite below and above boundaries reserve effective output and enforce independent byte guard" do
    messages = [%{role: "user", content: "hi"}]
    opts = [model: "unknown", max_tokens: 827, budget_settings: %{context_window_tokens: 1_000}]
    assert {:ok, fitting} = RequestPreparation.prepare(OpenAI, messages, "", opts)
    assert fitting.metrics.estimated_tokens + 827 <= 1_000

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError} = error} =
             RequestPreparation.prepare(OpenAI, messages, "", Keyword.put(opts, :max_tokens, 828))

    assert error.estimated_tokens + 828 <= 1_000
    assert error.bytes > error.byte_limit
  end

  test "rolling summary never splits the first retained multi-call exchange" do
    messages = [
      %{role: "user", content: String.duplicate("old ", 2_000)},
      %{
        role: "assistant",
        content: "",
        budget_mandatory: true,
        tool_calls: [
          %{id: "c1", name: "read_file", args: %{}},
          %{id: "c2", name: "read_file", args: %{}}
        ]
      },
      %{role: "tool", tool_call_id: "c1", content: "first"},
      %{role: "tool", tool_call_id: "c2", content: "second"},
      %{role: "user", content: "current objective"}
    ]

    opts = [
      model: "unknown",
      max_tokens: 100,
      budget_settings: %{
        context_window_tokens: 800,
        context_compaction_strategy: "rolling_summary"
      }
    ]

    assert {:ok, prepared} = RequestPreparation.prepare(OpenAI, messages, "", opts)
    index = Enum.find_index(prepared.messages, &(Map.get(&1, :tool_calls) not in [nil, []]))
    assert Enum.at(prepared.messages, index + 1).role == "tool"
    assert Enum.at(prepared.messages, index + 2).role == "tool"
  end

  test "a required reply protects every message in its complete exchange from shortening" do
    messages = [
      %{role: "user", content: String.duplicate("old removable ", 2_000)},
      %{role: "user", content: "Current objective", budget_objective: true},
      %{
        role: "assistant",
        content: "Need a decision",
        budget_mandatory: true,
        tool_calls: [
          %{id: "read", name: "read_file", args: %{}},
          %{id: "ask", name: "request_input", args: %{}}
        ]
      },
      %{role: "tool", tool_call_id: "read", content: String.duplicate("complete output ", 300)},
      %{role: "tool", tool_call_id: "ask", content: "User answer: yes", budget_mandatory: true}
    ]

    opts = [
      model: "unknown",
      max_tokens: 100,
      budget_settings: %{
        context_window_tokens: 2_000,
        context_compaction_strategy: "token_compaction"
      }
    ]

    assert {:ok, prepared} = RequestPreparation.prepare(OpenAI, messages, "", opts)
    assert Enum.take(prepared.messages, -3) == Enum.take(messages, -3)
    refute Jason.encode!(prepared.body) =~ "budget_mandatory"
    refute Jason.encode!(prepared.body) =~ "budget_objective"
  end

  test "an oversized required request_input answer returns typed overflow instead of removal" do
    messages = [
      %{role: "user", content: "Current objective", budget_objective: true},
      %{
        role: "assistant",
        content: "Need a decision",
        budget_mandatory: true,
        tool_calls: [%{id: "ask", name: "request_input", args: %{}}]
      },
      %{
        role: "tool",
        tool_call_id: "ask",
        content: "User answer: " <> String.duplicate("required ", 3_000),
        budget_mandatory: true
      }
    ]

    opts = [
      model: "unknown",
      max_tokens: 100,
      budget_settings: %{
        context_window_tokens: 2_000,
        context_compaction_strategy: "sliding_window",
        keep_recent_turns: 6
      }
    ]

    assert {:error, %{__struct__: IexCode.LLM.RequestBudgetError} = error} =
             RequestPreparation.prepare(OpenAI, messages, "", opts)

    assert Exception.message(error) =~ "No model request was sent"
  end
end
