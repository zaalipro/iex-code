defmodule IexCode.Test.LeanWorkspaceFixture do
  @moduledoc false
  import Plug.Conn

  @original "name=lean-fixture\nanswer=41\n"
  @updated "name=lean-fixture\nanswer=42\n"

  def original, do: @original
  def updated, do: @updated
  def objective, do: "Inspect fixture.txt, find answer, and change only answer=41 to answer=42."

  def respond(conn, receiver) do
    body = conn.body_params
    system = body["messages"] |> hd() |> Map.fetch!("content")

    role =
      cond do
        String.contains?(system, "Master Planner") -> :planner
        String.contains?(system, "durable single") -> :single
        true -> :coder
      end

    turn = Enum.count(body["messages"], &(&1["role"] == "tool"))
    {text, call} = response(role, turn)
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    {:ok, conn} = chunk(conn, frame(%{"content" => text}))
    send(receiver, {:fixture_waiting, self(), role, turn, body})

    conn = await_release(conn, 60)

    conn =
      if call do
        {:ok, conn} = chunk(conn, frame(%{"tool_calls" => [call]}))
        conn
      else
        {:ok, conn} = chunk(conn, frame(%{"content" => "\nVerified fixture result."}))
        conn
      end

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp response(:planner, _), do: {"Plan: inspect the synthetic answer and report it.", nil}
  defp response(:coder, _), do: {"Coder: fixture answer is 42; no additional edit needed.", nil}

  defp response(:single, 0),
    do: {"Reading the synthetic fixture.", tool("read_file", %{"path" => "fixture.txt"})}

  defp response(:single, 1),
    do: {"Searching the answer.", tool("grep_search", %{"query" => "answer=", "path" => "."})}

  defp response(:single, 2),
    do:
      {"Requesting the scoped edit.",
       tool("write_file", %{"path" => "fixture.txt", "content" => @updated})}

  defp response(:single, 3), do: {"Changed fixture.txt from answer=41 to answer=42.", nil}

  defp tool(name, arguments) do
    %{
      "index" => 0,
      "id" => "fixture-#{name}",
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
    }
  end

  defp frame(delta),
    do: "data: " <> Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta}]}) <> "\n\n"

  defp await_release(_conn, 0), do: raise("workspace fixture was not released")

  defp await_release(conn, remaining) do
    receive do
      :release ->
        conn
    after
      1_000 ->
        {:ok, conn} = chunk(conn, ": fixture keepalive\n\n")
        await_release(conn, remaining - 1)
    end
  end
end
