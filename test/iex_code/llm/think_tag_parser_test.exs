defmodule IexCode.LLM.ThinkTagParserTest do
  use ExUnit.Case, async: true
  alias IexCode.LLM.ThinkTagParser

  describe "process_chunk/2 and parse_stream_delta/2" do
    test "processes plain text without any think tags" do
      parser = ThinkTagParser.new()

      {text1, reason1, parser} = ThinkTagParser.process_chunk(parser, "Hello world! ")
      assert text1 == "Hello world! "
      assert reason1 == ""

      {text2, reason2, _parser} = ThinkTagParser.process_chunk(parser, "How are you?")
      assert text2 == "How are you?"
      assert reason2 == ""
    end

    test "parses complete think tag within a single chunk" do
      parser = ThinkTagParser.new()
      chunk = "Prefix <think>internal reasoning steps</think> suffix output"

      {text, reason, _parser} = ThinkTagParser.process_chunk(parser, chunk)
      assert text == "Prefix  suffix output"
      assert reason == "internal reasoning steps"
    end

    test "buffers and reconstructs <think> opening tag split across chunk boundaries" do
      parser = ThinkTagParser.new()

      # Chunk 1 ends with partial tag "<thi"
      {text1, reason1, parser} = ThinkTagParser.process_chunk(parser, "Answer: <thi")
      assert text1 == "Answer: "
      assert reason1 == ""

      # Chunk 2 completes the opening tag "nk>thinking hard"
      {text2, reason2, parser} = ThinkTagParser.process_chunk(parser, "nk>thinking hard")
      assert text2 == ""
      assert reason2 == "thinking hard"

      # Chunk 3 streams more reasoning
      {text3, reason3, parser} = ThinkTagParser.process_chunk(parser, " and calculating")
      assert text3 == ""
      assert reason3 == " and calculating"

      # Chunk 4 closes the think tag and returns to text
      {text4, reason4, _parser} = ThinkTagParser.process_chunk(parser, "</think>Result: 42")
      assert text4 == "Result: 42"
      assert reason4 == ""
    end

    test "buffers and reconstructs </think> closing tag split across chunk boundaries" do
      parser = ThinkTagParser.new()

      # Open think block
      {text1, reason1, parser} = ThinkTagParser.process_chunk(parser, "<think>Let me see.")
      assert text1 == ""
      assert reason1 == "Let me see."

      # Chunk 2 ends with partial closing tag "</th"
      {text2, reason2, parser} = ThinkTagParser.process_chunk(parser, " All good.</th")
      assert text2 == ""
      assert reason2 == " All good."

      # Chunk 3 completes "</think>" and provides answer
      {text3, reason3, _parser} = ThinkTagParser.process_chunk(parser, "ink>Done!")
      assert text3 == "Done!"
      assert reason3 == ""
    end

    test "handles extreme character-by-character streaming of tags" do
      chunks = [
        "A",
        "<",
        "t",
        "h",
        "i",
        "n",
        "k",
        ">",
        "r",
        "e",
        "a",
        "s",
        "o",
        "n",
        "<",
        "/",
        "t",
        "h",
        "i",
        "n",
        "k",
        ">",
        "B"
      ]

      {final_text, final_reason, _} =
        Enum.reduce(chunks, {"", "", ThinkTagParser.new()}, fn chunk, {acc_t, acc_r, parser} ->
          {t, r, updated} = ThinkTagParser.process_chunk(parser, chunk)
          {acc_t <> t, acc_r <> r, updated}
        end)

      assert final_text == "AB"
      assert final_reason == "reason"
    end

    test "does not misidentify comparison operators as think tags" do
      parser = ThinkTagParser.new()

      {text, reason, parser} = ThinkTagParser.process_chunk(parser, "if x < 10 and y > 5 do")
      assert text == "if x < 10 and y > 5 do"
      assert reason == ""

      # Flush trailing buffer if any
      {flush_t, flush_r, _} = ThinkTagParser.flush(parser)
      assert flush_t == ""
      assert flush_r == ""
    end

    test "parse_stream_delta/2 maintains state across calls" do
      {text1, reason1, state1} = ThinkTagParser.parse_stream_delta("Hello <think>analyzing", nil)
      assert text1 == "Hello "
      assert reason1 == "analyzing"

      {text2, reason2, _state2} = ThinkTagParser.parse_stream_delta(" code</think> done", state1)
      assert text2 == " done"
      assert reason2 == " code"
    end
  end

  describe "extract/1" do
    test "extracts think block from complete non-streaming text" do
      input = "Summary\n<think>I need to sort the keys.</think>\nResult: [1, 2, 3]"
      {thought, clean} = ThinkTagParser.extract(input)

      assert thought == "I need to sort the keys."
      assert clean == "Summary\n\nResult: [1, 2, 3]"
    end

    test "extracts multiple think blocks" do
      input = "<think>Step 1</think>Part 1<think>Step 2</think>Part 2"
      {thought, clean} = ThinkTagParser.extract(input)

      assert thought == "Step 1\n\nStep 2"
      assert clean == "Part 1Part 2"
    end

    test "returns nil thought when no think tags are present" do
      input = "Just normal response text."
      {thought, clean} = ThinkTagParser.extract(input)

      assert is_nil(thought)
      assert clean == "Just normal response text."
    end
  end
end
