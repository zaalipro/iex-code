defmodule IexCode.Engine.PlanStore do
  @moduledoc """
  Ephemeral per-run store for agent autonomy state: task plans, input
  requests, and pause bundles used by pause/resume.

  Keyed by run id. Entries are process memory only; durable run history
  stays in the database. Callers should `clear/2` a run when it finishes.
  """

  use GenServer

  @type step :: %{required(String.t()) => String.t()}
  @type run_state :: %{plan: [step()], input_request: map() | nil, pause: map() | nil}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Replaces the plan steps for a run. Each step needs a title."
  @spec update_plan(GenServer.server(), String.t(), list()) ::
          {:ok, [step()]} | {:error, term()}
  def update_plan(server \\ __MODULE__, run_id, steps) when is_binary(run_id) do
    GenServer.call(server, {:update_plan, run_id, steps})
  end

  @doc "Returns the current plan steps for a run (empty list when unknown)."
  @spec get_plan(GenServer.server(), String.t()) :: [step()]
  def get_plan(server \\ __MODULE__, run_id) when is_binary(run_id) do
    GenServer.call(server, {:get_plan, run_id})
  end

  @doc "Records a pending input request for a run."
  @spec put_input_request(GenServer.server(), String.t(), map()) :: :ok
  def put_input_request(server \\ __MODULE__, run_id, request)
      when is_binary(run_id) and is_map(request) do
    GenServer.call(server, {:put_input_request, run_id, request})
  end

  @doc "Takes (and clears) the pending input request for a run."
  @spec take_input_request(GenServer.server(), String.t()) :: map() | nil
  def take_input_request(server \\ __MODULE__, run_id) when is_binary(run_id) do
    GenServer.call(server, {:take_input_request, run_id})
  end

  @doc "Stores a pause bundle used by `AgentLoop.resume/5`."
  @spec put_pause(GenServer.server(), String.t(), map()) :: :ok
  def put_pause(server \\ __MODULE__, run_id, bundle)
      when is_binary(run_id) and is_map(bundle) do
    GenServer.call(server, {:put_pause, run_id, bundle})
  end

  @doc "Takes (and clears) the pause bundle for a run."
  @spec take_pause(GenServer.server(), String.t()) :: map() | nil
  def take_pause(server \\ __MODULE__, run_id) when is_binary(run_id) do
    GenServer.call(server, {:take_pause, run_id})
  end

  @doc "Drops all autonomy state for a run."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(server \\ __MODULE__, run_id) when is_binary(run_id) do
    GenServer.call(server, {:clear, run_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:update_plan, run_id, steps}, _from, runs) do
    case normalize_steps(steps) do
      {:ok, normalized} ->
        entry = run_entry(runs, run_id)
        {:reply, {:ok, normalized}, Map.put(runs, run_id, %{entry | plan: normalized})}

      {:error, _reason} = error ->
        {:reply, error, runs}
    end
  end

  def handle_call({:get_plan, run_id}, _from, runs) do
    {:reply, run_entry(runs, run_id).plan, runs}
  end

  def handle_call({:put_input_request, run_id, request}, _from, runs) do
    entry = run_entry(runs, run_id)
    {:reply, :ok, Map.put(runs, run_id, %{entry | input_request: request})}
  end

  def handle_call({:take_input_request, run_id}, _from, runs) do
    entry = run_entry(runs, run_id)
    {:reply, entry.input_request, Map.put(runs, run_id, %{entry | input_request: nil})}
  end

  def handle_call({:put_pause, run_id, bundle}, _from, runs) do
    entry = run_entry(runs, run_id)
    {:reply, :ok, Map.put(runs, run_id, %{entry | pause: bundle})}
  end

  def handle_call({:take_pause, run_id}, _from, runs) do
    entry = run_entry(runs, run_id)
    {:reply, entry.pause, Map.put(runs, run_id, %{entry | pause: nil})}
  end

  def handle_call({:clear, run_id}, _from, runs) do
    {:reply, :ok, Map.delete(runs, run_id)}
  end

  defp run_entry(runs, run_id) do
    Map.get(runs, run_id, %{plan: [], input_request: nil, pause: nil})
  end

  defp normalize_steps(steps) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, acc} ->
      case normalize_step(step, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_steps(_steps), do: {:error, :plan_steps_must_be_a_list}

  defp normalize_step(%{"title" => title} = step, index) when is_binary(title) do
    title = String.trim(title)

    if title == "" do
      {:error, {:plan_step_missing_title, index}}
    else
      {:ok,
       %{
         "title" => String.slice(title, 0, 500),
         "status" => normalize_status(Map.get(step, "status")),
         "detail" => String.slice(to_string(Map.get(step, "detail", "")), 0, 2_000)
       }}
    end
  end

  defp normalize_step(_step, index), do: {:error, {:plan_step_missing_title, index}}

  defp normalize_status(status) when status in ~w(pending in_progress done), do: status
  defp normalize_status(_status), do: "pending"
end
