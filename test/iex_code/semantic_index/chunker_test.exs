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

  describe "Tier 3: Polyglot Symbol-Aware Chunking" do
    test "chunks TypeScript and JavaScript files into interface, type, class, method, and function chunks" do
      ts_code = """
      export interface UserProfile {
        id: string;
        name: string;
      }

      export type UserId = string;

      export class UserService {
        private count = 0;

        async findUser(id: UserId): Promise<UserProfile | null> {
          return { id, name: "Ada" };
        }
      }

      export function formatUser(user: UserProfile): string {
        return `${user.name} (${user.id})`;
      }

      export const isAdmin = (id: string) => id === "root";
      """

      chunks = Chunker.chunk_file("src/user_service.ts", ts_code)

      iface = Enum.find(chunks, &(&1.symbol_name == "UserProfile"))
      assert iface.chunk_type == "interface"
      assert iface.symbol_type == "interface"
      assert iface.start_line == 1
      assert iface.end_line == 4
      assert iface.content =~ "File: src/user_service.ts | interface UserProfile"

      type_chunk = Enum.find(chunks, &(&1.symbol_name == "UserId"))
      assert type_chunk.chunk_type == "type"
      assert type_chunk.start_line == 6
      assert type_chunk.end_line == 6
      assert type_chunk.content =~ "File: src/user_service.ts | type UserId"

      class_chunk = Enum.find(chunks, &(&1.symbol_name == "UserService"))
      assert class_chunk.chunk_type == "class"
      assert class_chunk.start_line == 8
      assert class_chunk.end_line == 14
      assert class_chunk.content =~ "File: src/user_service.ts | class UserService"

      method_chunk = Enum.find(chunks, &(&1.symbol_name == "findUser"))
      assert method_chunk.chunk_type == "method"
      assert method_chunk.symbol_type == "method"
      assert method_chunk.start_line == 11
      assert method_chunk.end_line == 13
      assert method_chunk.content =~ "File: src/user_service.ts | method findUser"

      fn_chunk = Enum.find(chunks, &(&1.symbol_name == "formatUser"))
      assert fn_chunk.chunk_type == "function"
      assert fn_chunk.start_line == 16
      assert fn_chunk.end_line == 18
      assert fn_chunk.content =~ "File: src/user_service.ts | function formatUser"

      arrow_chunk = Enum.find(chunks, &(&1.symbol_name == "isAdmin"))
      assert arrow_chunk.chunk_type == "function"
      assert arrow_chunk.start_line == 20
      assert arrow_chunk.end_line == 20

      # Also verify .jsx/.tsx/.js extensions route through polyglot chunker
      jsx_chunks =
        Chunker.chunk_file("web/Button.tsx", "export function Button() { return <button />; }\n")

      assert [%{symbol_name: "Button", chunk_type: "function"}] = jsx_chunks
    end

    test "chunks Python files into class, method, and function chunks with indentation boundaries" do
      py_code = """
      class JobQueue:
          def __init__(self, limit):
              self.limit = limit

          async def enqueue(
              self,
              item
          ):
              return item

      def run_worker(queue):
          return queue.limit
      """

      chunks = Chunker.chunk_file("worker/queue.py", py_code)

      cls = Enum.find(chunks, &(&1.symbol_name == "JobQueue"))
      assert cls.chunk_type == "class"
      assert cls.start_line == 1
      assert cls.end_line == 9
      assert cls.content =~ "File: worker/queue.py | class JobQueue"

      init_m = Enum.find(chunks, &(&1.symbol_name == "__init__"))
      assert init_m.chunk_type == "method"
      assert init_m.start_line == 2
      assert init_m.end_line == 3

      enq_m = Enum.find(chunks, &(&1.symbol_name == "enqueue"))
      assert enq_m.chunk_type == "method"
      assert enq_m.start_line == 5
      assert enq_m.end_line == 9
      assert enq_m.content =~ "File: worker/queue.py | method enqueue"

      top_fn = Enum.find(chunks, &(&1.symbol_name == "run_worker"))
      assert top_fn.chunk_type == "function"
      assert top_fn.start_line == 11
      assert top_fn.end_line == 12
      assert top_fn.content =~ "File: worker/queue.py | function run_worker"
    end

    test "chunks Go files into struct, interface, type, method, and function chunks" do
      go_code = """
      package server

      type Config struct {
          Port int
      }

      type Handler interface {
          Serve() error
      }

      type Port int

      func (c *Config) Addr() string {
          return ":8080"
      }

      func Start(cfg Config) error {
          return nil
      }
      """

      chunks = Chunker.chunk_file("cmd/server.go", go_code)

      st = Enum.find(chunks, &(&1.symbol_name == "Config"))
      assert st.chunk_type == "struct"
      assert st.start_line == 3
      assert st.end_line == 5
      assert st.content =~ "File: cmd/server.go | struct Config"

      iface = Enum.find(chunks, &(&1.symbol_name == "Handler"))
      assert iface.chunk_type == "interface"
      assert iface.start_line == 7
      assert iface.end_line == 9

      alias_t = Enum.find(chunks, &(&1.symbol_name == "Port"))
      assert alias_t.chunk_type == "type"
      assert alias_t.start_line == 11
      assert alias_t.end_line == 11

      meth = Enum.find(chunks, &(&1.symbol_name == "Addr"))
      assert meth.chunk_type == "method"
      assert meth.start_line == 13
      assert meth.end_line == 15
      assert meth.content =~ "File: cmd/server.go | method Addr"

      func_c = Enum.find(chunks, &(&1.symbol_name == "Start"))
      assert func_c.chunk_type == "function"
      assert func_c.start_line == 17
      assert func_c.end_line == 19
    end

    test "chunks Rust files into struct, trait, impl, method, and function chunks safely with lifetimes" do
      rs_code = """
      pub struct Engine<'a> {
          name: &'a str,
      }

      pub trait Runner {
          fn run(&self) -> bool;
      }

      impl<'a> Engine<'a> {
          pub fn has_brace(&self, ch: char) -> bool {
              ch == '{'
          }
      }

      pub fn boot() -> bool {
          true
      }
      """

      chunks = Chunker.chunk_file("src/engine.rs", rs_code)

      st = Enum.find(chunks, &(&1.symbol_name == "Engine"))
      assert st.chunk_type == "struct"
      assert st.start_line == 1
      assert st.end_line == 3

      tr = Enum.find(chunks, &(&1.symbol_name == "Runner"))
      assert tr.chunk_type == "interface"
      assert tr.symbol_type == "trait"
      assert tr.start_line == 5
      assert tr.end_line == 7

      imp = Enum.find(chunks, &(&1.chunk_type == "impl"))
      assert imp.symbol_name == "Engine<'a>"
      assert imp.start_line == 9
      assert imp.end_line == 13
      assert imp.content =~ "File: src/engine.rs | impl Engine<'a>"

      meth = Enum.find(chunks, &(&1.symbol_name == "has_brace"))
      assert meth.chunk_type == "method"
      assert meth.start_line == 10
      assert meth.end_line == 12

      top_fn = Enum.find(chunks, &(&1.symbol_name == "boot"))
      assert top_fn.chunk_type == "function"
      assert top_fn.start_line == 15
      assert top_fn.end_line == 17
    end

    test "falls back to windowed line chunking when polyglot file has no declarations" do
      lines = for i <- 1..60, do: "// statement #{i}"
      content = Enum.join(lines, "\n")

      chunks = Chunker.chunk_file("scripts/plain.ts", content)
      assert length(chunks) >= 1
      assert Enum.all?(chunks, &(&1.chunk_type == "text"))
      assert hd(chunks).content =~ "File: scripts/plain.ts [lines 1-50]"
    end
  end
end
