defmodule IexCode.SemanticIndex.ChunkerTest do
  @moduledoc """
  Requirement R2: Offline Local Semantic Codebase Indexing & Vector Search.
  Tests for IexCode.SemanticIndex.Chunker:
  - AST symbol extraction for Elixir code (.ex, .exs)
  - Windowed sliding line chunker for non-Elixir files (.md, .json, .heex)
  - Boundary line ranges, context headers, and syntax error fallbacks
  """
  use ExUnit.Case, async: true

  alias IexCode.SemanticIndex.Chunker

  @sample_elixir_code """
  defmodule Calculator.MathCore do
    @moduledoc \"\"\"
    Performs core mathematical computations.
    \"\"\"

    @type number_pair :: {number(), number()}

    @doc \"\"\"
    Adds two numbers together.
    \"\"\"
    @spec add(number(), number()) :: number()
    def add(a, b) when is_number(a) and is_number(b) do
      a + b
    end

    @doc \"\"\"
    Subtracts b from a.
    \"\"\"
    def subtract(a, b) do
      a - b
    end
  end
  """

  describe "Tier 1: Elixir AST Chunking" do
    test "T1_R2_CHK_01: chunks Elixir module and functions with metadata" do
      chunks = Chunker.chunk_file("lib/math_core.ex", @sample_elixir_code)

      assert is_list(chunks)
      assert length(chunks) >= 2

      add_chunk =
        Enum.find(chunks, fn c ->
          c.symbol_name =~ "add" and c.chunk_type in ["function", "def", :function, :def]
        end)

      assert add_chunk != nil
      assert to_string(add_chunk.chunk_type) in ["function", "def"]
      assert add_chunk.start_line >= 6
      assert add_chunk.end_line >= add_chunk.start_line
      assert add_chunk.content =~ "def add(a, b)"
      assert add_chunk.content =~ "lib/math_core.ex"
    end

    test "T1_R2_CHK_02: extracts module header chunk with moduledoc" do
      chunks = Chunker.chunk_file("lib/math_core.ex", @sample_elixir_code)

      mod_chunk =
        Enum.find(chunks, fn c ->
          to_string(c.chunk_type) =~ "module" or to_string(c.symbol_type) =~ "module"
        end)

      assert mod_chunk != nil
      assert mod_chunk.symbol_name =~ "Calculator.MathCore"
      assert mod_chunk.content =~ "Performs core mathematical computations"
    end

    test "T1_R2_CHK_03: extracts typespec chunk or incorporates types" do
      chunks = Chunker.chunk_file("lib/math_core.ex", @sample_elixir_code)

      assert Enum.any?(chunks, fn c ->
               c.content =~ "number_pair" or (c.symbol_name && c.symbol_name =~ "number_pair")
             end)
    end
  end

  describe "Tier 1: Non-Elixir Sliding Window Chunking" do
    test "T1_R2_CHK_04: sliding window chunking for Markdown files (.md)" do
      lines =
        for i <- 1..120, do: "Line #{i}: Autonomous engineering notes and architecture patterns."

      md_content = Enum.join(lines, "\n")

      chunks = Chunker.chunk_file("docs/architecture.md", md_content)

      assert is_list(chunks)
      assert length(chunks) >= 2

      first = Enum.at(chunks, 0)
      assert to_string(first.chunk_type) == "text"
      assert first.start_line == 1
      assert first.end_line <= 50
      assert first.content =~ "Line 1"
    end

    test "T1_R2_CHK_05: sliding window chunking for JSON / Config files" do
      json =
        Jason.encode!(%{key1: "val1", key2: "val2", items: Enum.to_list(1..30)}, pretty: true)

      chunks = Chunker.chunk_file("config/runtime.json", json)

      assert is_list(chunks)
      assert length(chunks) >= 1
      assert Enum.at(chunks, 0).content =~ "key1"
    end
  end

  describe "Tier 2: Boundary Conditions & Edge Cases" do
    test "T2_R2_CHK_01: empty file returns clean empty or minimal chunk list without crashing" do
      res1 = Chunker.chunk_file("lib/empty.ex", "")
      res2 = Chunker.chunk_file("docs/empty.md", "")

      assert is_list(res1)
      assert is_list(res2)
    end

    test "T2_R2_CHK_02: syntax error in Elixir file falls back to line chunking without raising" do
      malformed_elixir = """
      defmodule BrokenCode do
        def incomplete(
        # missing closing parens and end
      """

      chunks = Chunker.chunk_file("lib/broken.ex", malformed_elixir)

      assert is_list(chunks)
      assert length(chunks) >= 1
      assert Enum.at(chunks, 0).content =~ "defmodule BrokenCode"
    end

    test "T2_R2_CHK_03: single-line file produces single chunk" do
      chunks = Chunker.chunk_file("lib/short.ex", "defmodule Short, do: :ok")

      assert length(chunks) == 1
      assert Enum.at(chunks, 0).start_line == 1
      assert Enum.at(chunks, 0).end_line == 1
    end

    test "T2_R2_CHK_04: unicode, emojis, and special characters preserved in chunk content" do
      content = """
      defmodule International do
        # 🚀 Autonomic swarm running on Apple Silicon M-Series ⚡️
        # UTF-8: こんにちは 世界 / Привет мир / Café & résumé
        def run(arg), do: arg
      end
      """

      chunks = Chunker.chunk_file("lib/intl.ex", content)

      assert length(chunks) >= 1
      assert Enum.any?(chunks, fn c -> c.content =~ "🚀" and c.content =~ "こんにちは" end)
    end
  end
end
