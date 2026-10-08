defmodule IexCode.Tools.NativeRead do
  @moduledoc false
  alias IexCode.Tools.BoundedFile

  def read(path, args) do
    start = Map.get(args, "start_line")
    finish = Map.get(args, "end_line")
    offset = if is_integer(start), do: max(0, start - 1), else: 0
    first_number = if is_integer(start), do: start, else: 1

    count =
      cond do
        is_integer(start) and is_integer(finish) and start <= finish ->
          max(1, finish - start + 1)

        is_integer(start) ->
          :infinity

        true ->
          800
      end

    callback = fn line, index, acc ->
      cond do
        index <= offset ->
          {:cont, acc}

        true ->
          text = "#{first_number + acc.count}: #{line}"
          bytes = byte_size(text) + if(acc.count > 0, do: 1, else: 0)

          if acc.bytes + bytes > BoundedFile.limits().output_bytes do
            {:halt, :output, acc}
          else
            acc = %{lines: [text | acc.lines], count: acc.count + 1, bytes: acc.bytes + bytes}

            if acc.count == count do
              reason = if is_integer(start), do: :range, else: :line_limit
              {:halt, reason, acc}
            else
              {:cont, acc}
            end
          end
      end
    end

    with {:ok, result} <- BoundedFile.scan(path, %{lines: [], count: 0, bytes: 0}, callback) do
      body =
        result.acc.lines |> Enum.reverse() |> Enum.join("\n") |> IexCode.Sessions.sanitize_utf8()

      suffix =
        case result.reason do
          reason when reason in [nil, :range] ->
            ""

          reason ->
            "\n[truncated/incomplete: #{description(reason)}; scanned #{result.bytes} bytes, " <>
              "at least #{result.lines} lines. Use start_line/end_line to narrow the range; " <>
              "split oversized files or giant lines when the scan cannot reach it.]"
        end

      output = body <> suffix

      :telemetry.execute(
        [:iex_code, :tools, :native_scan],
        %{
          scanned_bytes: result.bytes,
          scanned_lines: result.lines,
          output_bytes: byte_size(output),
          output_lines: result.acc.count
        },
        %{tool: :read_file}
      )

      {:ok, output, result.acc.count}
    else
      {:error, reason, _bytes} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp description(:line_limit), do: "800-line limit"
  defp description(:output), do: "output byte limit"
  defp description(:scan), do: "scan byte limit"
  defp description(:giant_line), do: "giant line limit"
end
