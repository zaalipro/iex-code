defmodule IexCode.Eval.Round3BenchmarkTasksTest do
  use ExUnit.Case, async: true

  alias IexCode.Eval.{Runner, Task}

  @ast_fixed_source """
  defmodule AstRenamer do
    @moduledoc \"\"\"
    AST-aware Elixir function renaming utility.
    \"\"\"

    @spec rename_function(String.t(), atom(), atom(), non_neg_integer()) ::
            {:ok, String.t()} | {:error, term()}
    def rename_function(source, old_name, new_name, arity)
        when is_binary(source) and is_atom(old_name) and is_atom(new_name) and
               is_integer(arity) and arity >= 0 do
      with {:ok, ast} <- Code.string_to_quoted(source) do
        updated_ast =
          Macro.prewalk(ast, fn
            {def_kind, def_meta, [{:when, when_meta, [{^old_name, fn_meta, args}, guard]}, body]}
            when def_kind in [:def, :defp] and
                   ((is_nil(args) and arity == 0) or (is_list(args) and length(args) == arity)) ->
              {def_kind, def_meta,
               [{:when, when_meta, [{new_name, fn_meta, args}, guard]}, body]}

            {def_kind, def_meta, [{^old_name, fn_meta, args}, body]}
            when def_kind in [:def, :defp] and
                   ((is_nil(args) and arity == 0) or (is_list(args) and length(args) == arity)) ->
              {def_kind, def_meta, [{new_name, fn_meta, args}, body]}

            {:&, cap_meta, [{:/, slash_meta, [{^old_name, fn_meta, ctx}, ^arity]}]}
            when is_atom(ctx) ->
              {:&, cap_meta, [{:/, slash_meta, [{new_name, fn_meta, ctx}, arity]}]}

            {:&, cap_meta,
             [{:/, slash_meta, [{{:., dot_meta, [mod, ^old_name]}, call_meta, []}, ^arity]}]} ->
              {:&, cap_meta,
               [{:/, slash_meta, [{{:., dot_meta, [mod, new_name]}, call_meta, []}, arity]}]}

            {{:., dot_meta, [mod, ^old_name]}, call_meta, args}
            when is_list(args) and length(args) == arity ->
              {{:., dot_meta, [mod, new_name]}, call_meta, args}

            {^old_name, call_meta, args}
            when is_list(args) and length(args) == arity ->
              {new_name, call_meta, args}

            other ->
              other
          end)

        {:ok, Macro.to_string(updated_ast)}
      end
    end
  end
  """

  @jsonrpc_fixed_source """
  defmodule JsonRpcFramer do
    @moduledoc \"\"\"
    Streaming Content-Length framer for JSON-RPC / LSP / MCP stdio transports.
    \"\"\"

    @default_max_bytes 1_048_576

    @type t :: %{buffer: binary(), max_content_length: pos_integer()}

    @spec new(keyword()) :: t()
    def new(opts \\\\ []) do
      %{
        buffer: "",
        max_content_length: Keyword.get(opts, :max_content_length, @default_max_bytes)
      }
    end

    @spec encode(binary()) :: binary()
    def encode(payload) when is_binary(payload) do
      "Content-Length: \#{byte_size(payload)}\\r\\n\\r\\n" <> payload
    end

    @spec feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, term(), t()}
    def feed(%{buffer: buffer} = state, chunk) when is_binary(chunk) do
      extract_frames(buffer <> chunk, state, [])
    end

    defp extract_frames(buffer, state, acc) do
      case :binary.match(buffer, "\\r\\n\\r\\n") do
        {header_len, 4} ->
          header_block = binary_part(buffer, 0, header_len)
          rest = binary_part(buffer, header_len + 4, byte_size(buffer) - header_len - 4)

          case parse_content_length(header_block, state.max_content_length) do
            {:ok, content_length} ->
              if byte_size(rest) >= content_length do
                payload = binary_part(rest, 0, content_length)
                remaining = binary_part(rest, content_length, byte_size(rest) - content_length)
                extract_frames(remaining, state, [payload | acc])
              else
                {:ok, Enum.reverse(acc), %{state | buffer: buffer}}
              end

            {:error, reason} ->
              {:error, reason, %{state | buffer: ""}}
          end

        :nomatch ->
          {:ok, Enum.reverse(acc), %{state | buffer: buffer}}
      end
    end

    defp parse_content_length(header_block, max_bytes) do
      headers =
        header_block
        |> String.split("\\r\\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [name, val] ->
              Map.put(acc, name |> String.trim() |> String.downcase(), String.trim(val))

            _ ->
              acc
          end
        end)

      case Map.fetch(headers, "content-length") do
        :error ->
          {:error, :missing_content_length}

        {:ok, raw} ->
          case Integer.parse(raw) do
            {len, ""} when len >= 0 and len <= max_bytes -> {:ok, len}
            {len, ""} when len > max_bytes -> {:error, :frame_too_large}
            _ -> {:error, :invalid_content_length}
          end
      end
    end
  end
  """

  test "tasks #9 and #10 load with valid metadata and fail in their baseline state" do
    assert {:ok, all_tasks} = Task.load_dir("eval/tasks")

    r3_tasks =
      Task.filter(all_tasks, only: ["elixir-ast-rename-refactor", "elixir-jsonrpc-frame-parser"])

    assert length(r3_tasks) == 2

    assert {:ok, baseline_results} =
             Runner.run("eval/tasks",
               only: ["elixir-ast-rename-refactor", "elixir-jsonrpc-frame-parser"],
               samples: 1,
               loop_fn: fn _prompt, _workdir, _task -> {:ok, %{turns: 0}} end
             )

    assert baseline_results.aggregate.samples == 2
    assert baseline_results.aggregate.passed == 0
  end

  test "tasks #9 and #10 pass when reference fixes are applied" do
    assert {:ok, fixed_results} =
             Runner.run("eval/tasks",
               only: ["elixir-ast-rename-refactor", "elixir-jsonrpc-frame-parser"],
               samples: 1,
               loop_fn: fn _prompt, workdir, task ->
                 case task.id do
                   "elixir-ast-rename-refactor" ->
                     File.write!(Path.join(workdir, "lib/ast_renamer.ex"), @ast_fixed_source)

                   "elixir-jsonrpc-frame-parser" ->
                     File.write!(
                       Path.join(workdir, "lib/jsonrpc_framer.ex"),
                       @jsonrpc_fixed_source
                     )
                 end

                 {:ok, %{turns: 1}}
               end
             )

    assert fixed_results.aggregate.samples == 2
    assert fixed_results.aggregate.passed == 2
    assert fixed_results.aggregate.pass_rate == 1.0
  end
end
