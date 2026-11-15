defmodule IexCode.Tools.LSPClient do
  @moduledoc """
  Stdio Language Server Protocol (LSP) JSON-RPC 2.0 client.

  Communicates with an external language server process over stdio using
  `Content-Length: <bytes>\\r\\n\\r\\n<json>` framing, handling partial frames,
  coalesced packets, UTF-8 byte lengths, and bounded read buffers.

  Supports:
    * `initialize` + `initialized` notification
    * `textDocument/didOpen`
    * `textDocument/definition`
    * `textDocument/references`
    * `textDocument/hover`
    * `textDocument/documentSymbol`
    * `shutdown` + `exit`

  All file paths and `file://` URIs are strictly validated against `WorkspacePath`
  containment. External JSON payloads are decoded without `String.to_atom/1`.
  """

  use GenServer
  require Logger

  alias IexCode.WorkspacePath

  @default_timeout_ms 10_000
  @max_buffer_bytes 8_388_608

  @doc "Maximum buffered stdout bytes allowed before failing on framing overflow."
  @spec max_buffer_bytes() :: pos_integer()
  def max_buffer_bytes, do: @max_buffer_bytes

  @doc "Encodes a JSON-RPC message map with an LSP `Content-Length` byte header."
  @spec encode_frame(map()) :: {:ok, binary()} | {:error, term()}
  def encode_frame(payload) when is_map(payload) do
    with {:ok, json} <- Jason.encode(payload) do
      {:ok, "Content-Length: #{byte_size(json)}\r\n\r\n" <> json}
    end
  end

  @doc "Starts a linked `LSPClient` GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Starts an unlinked `LSPClient` GenServer."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc "Gracefully stops the LSP client, attempting `shutdown` + `exit` before closing the port."
  @spec stop(GenServer.server(), pos_integer()) :: :ok
  def stop(server, timeout \\ 5_000) do
    _ = shutdown(server, timeout_ms: min(timeout, 1_500))

    try do
      GenServer.stop(server, :normal, timeout)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc "Runs LSP `initialize` request followed by `initialized` notification."
  @spec initialize(GenServer.server(), keyword() | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def initialize(server, opts \\ []) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    with {:ok, params} <- GenServer.call(server, :initialize_params, timeout + 5_000),
         {:ok, result} <- dispatch_request(server, "initialize", params, timeout),
         :ok <- dispatch_notification(server, "initialized", %{}, timeout) do
      {:ok, result}
    else
      {:error, _} = err -> err
    end
  catch
    :exit, reason -> normalize_exit_error(reason)
  end

  @doc "Sends `textDocument/didOpen` notification for a workspace-contained file or `file://` URI."
  @spec did_open(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def did_open(server, file_path, opts \\ []) when is_binary(file_path) and is_list(opts) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    with {:ok, canonical_path, uri} <- resolve_server_uri(server, file_path, timeout),
         {:ok, text} <- read_open_text(canonical_path, opts) do
      language_id = Keyword.get(opts, :language_id) || infer_language_id(canonical_path)
      version = Keyword.get(opts, :version, 1)

      params = %{
        "textDocument" => %{
          "uri" => uri,
          "languageId" => language_id,
          "version" => version,
          "text" => text
        }
      }

      dispatch_notification(server, "textDocument/didOpen", params, timeout)
    end
  end

  @doc "Queries `textDocument/definition` at 0-based `line` and `character`."
  @spec definition(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def definition(server, file_path, line, character, opts \\ [])
      when is_binary(file_path) and is_integer(line) and line >= 0 and is_integer(character) and
             character >= 0 do
    position_request(server, "textDocument/definition", file_path, line, character, %{}, opts)
  end

  @doc "Queries `textDocument/references` at 0-based `line` and `character`."
  @spec references(
          GenServer.server(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def references(server, file_path, line, character, opts \\ [])
      when is_binary(file_path) and is_integer(line) and line >= 0 and is_integer(character) and
             character >= 0 do
    include_declaration = Keyword.get(opts, :include_declaration, true)
    extra = %{"context" => %{"includeDeclaration" => include_declaration}}
    position_request(server, "textDocument/references", file_path, line, character, extra, opts)
  end

  @doc "Queries `textDocument/hover` at 0-based `line` and `character`."
  @spec hover(GenServer.server(), String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def hover(server, file_path, line, character, opts \\ [])
      when is_binary(file_path) and is_integer(line) and line >= 0 and is_integer(character) and
             character >= 0 do
    position_request(server, "textDocument/hover", file_path, line, character, %{}, opts)
  end

  @doc "Queries `textDocument/documentSymbol` for a workspace-contained file or `file://` URI."
  @spec document_symbols(GenServer.server(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def document_symbols(server, file_path, opts \\ []) when is_binary(file_path) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    with {:ok, _canonical_path, uri} <- resolve_server_uri(server, file_path, timeout),
         {:ok, result} <-
           dispatch_request(
             server,
             "textDocument/documentSymbol",
             %{"textDocument" => %{"uri" => uri}},
             timeout
           ) do
      sanitize_response_uris(server, result, timeout)
    end
  end

  @doc "Sends LSP `shutdown` request followed by `exit` notification."
  @spec shutdown(GenServer.server(), keyword() | pos_integer()) :: :ok | {:error, term()}
  def shutdown(server, opts \\ []) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    case dispatch_request(server, "shutdown", nil, timeout) do
      {:ok, _} ->
        _ = dispatch_notification(server, "exit", nil, timeout)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  One-shot LSP query helper.

  Runs `start -> initialize -> didOpen -> <action> -> shutdown -> stop` inside a
  guaranteed cleanup block.

  Supports either:
    * `query(root_path, %{"action" => ..., "file" => ..., "line" => ..., "character" => ..., "server_cmd" => ...}, opts)`
    * `query(root_path, :definition | :references | :hover | :document_symbols, opts)`
  """
  @spec query(Path.t(), map() | atom() | String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def query(root_path, action_or_params, opts \\ [])

  def query(root_path, params, opts)
      when is_binary(root_path) and is_map(params) and is_list(opts) do
    action = Map.get(params, "action") || Map.get(params, :action)

    merged_opts =
      opts
      |> maybe_put(:file, Map.get(params, "file") || Map.get(params, :file))
      |> maybe_put(:line, Map.get(params, "line") || Map.get(params, :line))
      |> maybe_put(:character, Map.get(params, "character") || Map.get(params, :character))
      |> maybe_put(:server_cmd, Map.get(params, "server_cmd") || Map.get(params, :server_cmd))
      |> maybe_put(:command, Map.get(params, "command") || Map.get(params, :command))
      |> maybe_put(:args, Map.get(params, "args") || Map.get(params, :args))
      |> maybe_put(:text, Map.get(params, "text") || Map.get(params, :text))
      |> maybe_put(:language_id, Map.get(params, "language_id") || Map.get(params, :language_id))
      |> maybe_put(
        :include_declaration,
        Map.get(params, "include_declaration") || Map.get(params, :include_declaration)
      )

    query(root_path, action, merged_opts)
  end

  def query(root_path, action, opts)
      when is_binary(root_path) and (is_binary(action) or is_atom(action)) and is_list(opts) do
    action_str = to_string(action)
    file = Keyword.get(opts, :file)
    line = Keyword.get(opts, :line, 0)
    character = Keyword.get(opts, :character, 0)
    timeout = resolve_timeout(opts, @default_timeout_ms)

    with :ok <- validate_action(action_str),
         true <- (is_binary(file) and file != "") || {:error, :missing_file},
         :ok <- validate_non_neg_int(line, :invalid_line),
         :ok <- validate_non_neg_int(character, :invalid_character),
         {:ok, canonical_root} <- WorkspacePath.resolve(root_path, "."),
         {:ok, canonical_file, _uri} <- resolve_uri_in_root(canonical_root, file),
         {:ok, {command, args}} <- resolve_server_command(canonical_file, opts),
         {:ok, pid} <-
           start(
             command: command,
             args: args,
             root_path: canonical_root,
             env: Keyword.get(opts, :env, %{}),
             timeout_ms: timeout
           ) do
      try do
        with {:ok, _init} <- initialize(pid, timeout_ms: timeout),
             :ok <- did_open(pid, canonical_file, opts),
             {:ok, result} <-
               execute_action(pid, action_str, canonical_file, line, character, opts) do
          {:ok, result}
        end
      after
        stop(pid)
      end
    else
      false -> {:error, :missing_file}
      {:error, _} = err -> err
    end
  end

  def query(_root_path, _action, _opts), do: {:error, :invalid_query_args}

  @doc "Converts a canonical filesystem path into a `file://` URI."
  @spec path_to_uri(Path.t()) :: String.t()
  def path_to_uri(path) when is_binary(path) do
    encoded =
      URI.encode(path, fn c ->
        c == ?/ or c == ?: or URI.char_unreserved?(c)
      end)

    if String.starts_with?(encoded, "/") do
      "file://" <> encoded
    else
      "file:///" <> encoded
    end
  end

  @doc "Resolves a relative path, absolute path, or `file://` URI inside `root_path`."
  @spec resolve_uri_in_root(Path.t(), String.t()) ::
          {:ok, Path.t(), String.t()} | {:error, term()}
  def resolve_uri_in_root(root_path, path_or_uri)
      when is_binary(root_path) and is_binary(path_or_uri) do
    with {:ok, canonical_root} <- WorkspacePath.resolve(root_path, "."),
         {:ok, raw_path} <- extract_file_path(path_or_uri),
         {:ok, canonical_file} <- WorkspacePath.resolve(canonical_root, raw_path) do
      {:ok, canonical_file, path_to_uri(canonical_file)}
    end
  end

  def resolve_uri_in_root(_root_path, _other), do: {:error, :invalid_path}

  defp extract_file_path(<<"file://", _rest::binary>> = uri_str) do
    case URI.parse(uri_str) do
      %URI{scheme: "file", host: host, path: path}
      when host in [nil, "", "localhost"] and is_binary(path) and path != "" ->
        {:ok, URI.decode(path)}

      _ ->
        {:error, :invalid_file_uri}
    end
  end

  defp extract_file_path(other) do
    if String.contains?(other, "://") do
      {:error, :unsupported_uri_scheme}
    else
      {:ok, other}
    end
  end

  defp position_request(server, method, file_path, line, character, extra_params, opts) do
    timeout = resolve_timeout(opts, @default_timeout_ms)

    with {:ok, _canonical_path, uri} <- resolve_server_uri(server, file_path, timeout),
         params =
           Map.merge(
             %{
               "textDocument" => %{"uri" => uri},
               "position" => %{"line" => line, "character" => character}
             },
             extra_params
           ),
         {:ok, result} <- dispatch_request(server, method, params, timeout) do
      sanitize_response_uris(server, result, timeout)
    end
  end

  defp resolve_server_uri(server, file_path, timeout) do
    GenServer.call(server, {:resolve_uri, file_path}, timeout + 5_000)
  catch
    :exit, reason -> normalize_exit_error(reason)
  end

  defp sanitize_response_uris(_server, nil, _timeout), do: {:ok, nil}

  defp sanitize_response_uris(server, result, timeout)
       when is_list(result) or is_map(result) do
    GenServer.call(server, {:sanitize_result, result}, timeout + 5_000)
  catch
    :exit, reason -> normalize_exit_error(reason)
  end

  defp sanitize_response_uris(_server, result, _timeout), do: {:ok, result}

  defp dispatch_request(server, method, params, timeout) do
    GenServer.call(server, {:request, method, params, timeout}, timeout + 5_000)
  catch
    :exit, reason -> normalize_exit_error(reason)
  end

  defp dispatch_notification(server, method, params, timeout) do
    GenServer.call(server, {:notify, method, params}, timeout + 5_000)
  catch
    :exit, reason -> normalize_exit_error(reason)
  end

  defp normalize_exit_error({:timeout, _}), do: {:error, :lsp_request_timeout}
  defp normalize_exit_error({:normal, _}), do: {:error, :client_stopping}
  defp normalize_exit_error({:shutdown, _}), do: {:error, :client_stopping}
  defp normalize_exit_error({{:shutdown, _}, _}), do: {:error, :client_stopping}
  defp normalize_exit_error({:noproc, _}), do: {:error, :client_stopped}
  defp normalize_exit_error({reason, _}), do: {:error, {:lsp_client_exit, reason}}
  defp normalize_exit_error(reason), do: {:error, {:lsp_client_exit, reason}}

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    command = Keyword.get(opts, :command) || Keyword.get(opts, :server_cmd)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    root_raw = Keyword.get(opts, :root_path) || Keyword.get(opts, :workspace_root) || File.cwd!()
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_buffer = normalize_max_buffer(Keyword.get(opts, :max_buffer_bytes, @max_buffer_bytes))
    notify_parent = Keyword.get(opts, :notify_parent)

    with {:ok, canonical_root} <- WorkspacePath.resolve(root_raw, "."),
         {:ok, {cmd, cmd_args}} <- normalize_command_args(command, args),
         {:ok, executable} <- resolve_executable(cmd),
         {:ok, port} <- open_stdio_port(executable, cmd_args, env, canonical_root) do
      {:ok,
       %{
         port: port,
         os_pid: port_os_pid(port),
         root_path: canonical_root,
         buffer: "",
         next_id: 1,
         pending: %{},
         exited: nil,
         timeout_ms: timeout,
         max_buffer_bytes: max_buffer,
         notify_parent: notify_parent
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:initialize_params, _from, state) do
    params = %{
      "processId" => nil,
      "rootUri" => path_to_uri(state.root_path),
      "rootPath" => state.root_path,
      "workspaceFolders" => [
        %{
          "uri" => path_to_uri(state.root_path),
          "name" => Path.basename(state.root_path)
        }
      ],
      "capabilities" => %{
        "textDocument" => %{
          "hover" => %{"contentFormat" => ["markdown", "plaintext"]},
          "definition" => %{"linkSupport" => true},
          "references" => %{},
          "documentSymbol" => %{"hierarchicalDocumentSymbolSupport" => true}
        }
      }
    }

    {:reply, {:ok, params}, state}
  end

  def handle_call({:resolve_uri, file_path}, _from, state) do
    {:reply, resolve_uri_in_root(state.root_path, file_path), state}
  end

  def handle_call({:sanitize_result, result}, _from, state) do
    {:reply, validate_response_payload(result, state.root_path), state}
  end

  def handle_call({:request, _method, _params, _timeout}, _from, %{exited: status} = state)
      when not is_nil(status) do
    {:reply, {:error, {:lsp_server_exited, status}}, state}
  end

  def handle_call({:request, method, params, timeout}, from, state) do
    id = state.next_id

    payload =
      %{"jsonrpc" => "2.0", "id" => id, "method" => method}
      |> maybe_put_params(params)

    with {:ok, frame} <- encode_frame(payload),
         :ok <- safe_port_command(state.port, frame) do
      timer = Process.send_after(self(), {:request_timeout, id}, timeout)
      pending = Map.put(state.pending, id, %{from: from, timer: timer})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    else
      {:error, :port_closed} ->
        state = mark_port_exited(state, :epipe)
        {:reply, {:error, {:lsp_server_exited, :epipe}}, state}

      {:error, reason} ->
        {:reply, {:error, {:lsp_encode, reason}}, state}
    end
  end

  def handle_call({:notify, _method, _params}, _from, %{exited: status} = state)
      when not is_nil(status) do
    {:reply, {:error, {:lsp_server_exited, status}}, state}
  end

  def handle_call({:notify, method, params}, _from, state) do
    payload =
      %{"jsonrpc" => "2.0", "method" => method}
      |> maybe_put_params(params)

    with {:ok, frame} <- encode_frame(payload),
         :ok <- safe_port_command(state.port, frame) do
      {:reply, :ok, state}
    else
      {:error, :port_closed} ->
        state = mark_port_exited(state, :epipe)
        {:reply, {:error, {:lsp_server_exited, :epipe}}, state}

      {:error, reason} ->
        {:reply, {:error, {:lsp_encode, reason}}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, _bytes}}, %{port: port, exited: exited} = state)
      when not is_nil(exited) do
    {:noreply, state}
  end

  def handle_info({port, {:data, bytes}}, %{port: port} = state) when is_binary(bytes) do
    {:noreply, consume_data(state, bytes)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if is_nil(state.exited) do
      notify_parent_exit(state.notify_parent, {:lsp_server_exited, status})
      {:noreply, fail_all(%{state | exited: status}, {:lsp_server_exited, status})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    if is_nil(state.exited) do
      notify_parent_exit(state.notify_parent, {:lsp_server_exited, reason})
      {:noreply, fail_all(%{state | exited: reason}, {:lsp_server_exited, reason})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, parent, reason}, %{notify_parent: parent} = state)
      when is_pid(parent) do
    {:stop, reason, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :lsp_request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = fail_all(state, :client_stopping)
    close_port(state.port, state.os_pid, state.exited)
    :ok
  end

  # --- Content-Length Framing ---

  defp consume_data(state, <<>>), do: state

  defp consume_data(state, bytes) do
    buffer = state.buffer <> bytes

    if byte_size(buffer) > state.max_buffer_bytes do
      overflow_buffer(state)
    else
      extract_frames(%{state | buffer: buffer})
    end
  end

  defp extract_frames(%{exited: exited} = state) when not is_nil(exited), do: state

  defp extract_frames(%{buffer: buffer} = state) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        if byte_size(buffer) > state.max_buffer_bytes do
          overflow_buffer(state)
        else
          state
        end

      {header_len, 4} ->
        header_block = binary_part(buffer, 0, header_len)
        rest = binary_part(buffer, header_len + 4, byte_size(buffer) - header_len - 4)

        case parse_content_length(header_block, state.max_buffer_bytes) do
          {:ok, content_length} ->
            if byte_size(rest) >= content_length do
              payload = binary_part(rest, 0, content_length)
              remaining = binary_part(rest, content_length, byte_size(rest) - content_length)

              next_state =
                %{state | buffer: remaining}
                |> handle_json_payload(payload)

              if remaining == "" or not is_nil(next_state.exited) do
                next_state
              else
                extract_frames(next_state)
              end
            else
              state
            end

          {:error, :frame_too_large} ->
            overflow_buffer(state)

          {:error, reason} ->
            Logger.warning("lsp: invalid header (#{inspect(reason)}); closing port")
            close_port(state.port, state.os_pid, state.exited)
            fail_all(%{state | exited: {:lsp_bad_header, reason}}, {:lsp_bad_header, reason})
        end
    end
  end

  defp parse_content_length(header_block, max_bytes) do
    headers =
      header_block
      |> String.split("\r\n", trim: true)
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

  defp overflow_buffer(state) do
    Logger.warning("lsp: buffer exceeded #{state.max_buffer_bytes} bytes; closing port")
    close_port(state.port, state.os_pid, state.exited)
    notify_parent_exit(state.notify_parent, :lsp_buffer_overflow)
    fail_all(%{state | exited: :lsp_buffer_overflow}, :lsp_buffer_overflow)
  end

  defp handle_json_payload(state, payload) do
    # Never use `keys: :atoms` or String.to_atom on external JSON.
    case Jason.decode(payload) do
      {:ok, %{"id" => id, "method" => _method} = server_request} when not is_nil(id) ->
        ack_server_request(state, server_request)

      {:ok, %{"id" => id} = message} when not is_nil(id) ->
        deliver_response(state, id, message)

      {:ok, %{"method" => _method} = notification} ->
        notify_parent_message(state.notify_parent, notification)
        state

      {:ok, _other} ->
        state

      {:error, _reason} ->
        Logger.warning("lsp: dropping undecodable JSON-RPC payload")
        state
    end
  end

  defp ack_server_request(state, %{"id" => id}) do
    reply = %{"jsonrpc" => "2.0", "id" => id, "result" => nil}

    with {:ok, frame} <- encode_frame(reply),
         :ok <- safe_port_command(state.port, frame) do
      state
    else
      _ -> state
    end
  end

  defp deliver_response(state, id, message) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from, timer: timer}, pending} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, response_result(message))
        %{state | pending: pending}
    end
  end

  defp response_result(%{"result" => result}), do: {:ok, result}

  defp response_result(%{"error" => %{"code" => code, "message" => message}}),
    do: {:error, {:lsp_error, code, message}}

  defp response_result(%{"error" => error}), do: {:error, {:lsp_error, error}}
  defp response_result(_message), do: {:error, :lsp_bad_response}

  defp fail_all(state, reason) do
    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}, buffer: ""}
  end

  # --- Response URI Containment ---

  defp validate_response_payload(list, root_path) when is_list(list) do
    filtered =
      Enum.filter(list, fn item ->
        case check_item_uris(item, root_path) do
          :ok -> true
          {:error, _} -> false
        end
      end)

    {:ok, filtered}
  end

  defp validate_response_payload(map, root_path) when is_map(map) do
    case check_item_uris(map, root_path) do
      :ok -> {:ok, map}
      {:error, _} = err -> err
    end
  end

  defp validate_response_payload(other, _root_path), do: {:ok, other}

  defp check_item_uris(%{"uri" => uri}, root_path) when is_binary(uri) do
    case resolve_uri_in_root(root_path, uri) do
      {:ok, _, _} -> :ok
      {:error, _} -> {:error, :outside_workspace}
    end
  end

  defp check_item_uris(%{"targetUri" => uri}, root_path) when is_binary(uri) do
    case resolve_uri_in_root(root_path, uri) do
      {:ok, _, _} -> :ok
      {:error, _} -> {:error, :outside_workspace}
    end
  end

  defp check_item_uris(%{"location" => %{"uri" => uri}}, root_path) when is_binary(uri) do
    case resolve_uri_in_root(root_path, uri) do
      {:ok, _, _} -> :ok
      {:error, _} -> {:error, :outside_workspace}
    end
  end

  defp check_item_uris(_other, _root_path), do: :ok

  # --- Helpers ---

  defp execute_action(pid, "definition", file, line, character, opts),
    do: definition(pid, file, line, character, opts)

  defp execute_action(pid, "references", file, line, character, opts),
    do: references(pid, file, line, character, opts)

  defp execute_action(pid, "hover", file, line, character, opts),
    do: hover(pid, file, line, character, opts)

  defp execute_action(pid, "document_symbols", file, _line, _character, opts),
    do: document_symbols(pid, file, opts)

  defp validate_action(action)
       when action in ["definition", "references", "hover", "document_symbols"],
       do: :ok

  defp validate_action(other), do: {:error, {:unsupported_lsp_action, other}}

  defp validate_non_neg_int(val, _err) when is_integer(val) and val >= 0, do: :ok
  defp validate_non_neg_int(_val, err), do: {:error, err}

  defp resolve_server_command(canonical_file, opts) do
    explicit_cmd = Keyword.get(opts, :server_cmd) || Keyword.get(opts, :command)
    explicit_args = Keyword.get(opts, :args, [])

    if explicit_cmd do
      normalize_command_args(explicit_cmd, explicit_args)
    else
      ext = canonical_file |> Path.extname() |> String.downcase()
      detect_default_server(ext)
    end
  end

  defp detect_default_server(ext) do
    candidates =
      case ext do
        e when e in [".ex", ".exs"] ->
          [{"elixir-ls", []}]

        e when e in [".ts", ".tsx", ".js", ".jsx"] ->
          [{"typescript-language-server", ["--stdio"]}]

        ".py" ->
          [{"pyright-langserver", ["--stdio"]}, {"pylsp", []}]

        ".go" ->
          [{"gopls", ["serve"]}]

        ".rs" ->
          [{"rust-analyzer", []}]

        _ ->
          []
      end

    case Enum.find(candidates, fn {bin, _args} -> System.find_executable(bin) != nil end) do
      nil -> {:error, {:lsp_server_unavailable, ext}}
      found -> {:ok, found}
    end
  end

  defp normalize_command_args([cmd | rest], extra_args)
       when is_binary(cmd) and is_list(extra_args) do
    {:ok, {cmd, rest ++ extra_args}}
  end

  defp normalize_command_args(cmd, args) when is_binary(cmd) and cmd != "" and is_list(args) do
    {:ok, {cmd, args}}
  end

  defp normalize_command_args(_cmd, _args), do: {:error, :lsp_bad_command}

  defp read_open_text(canonical_path, opts) do
    case Keyword.get(opts, :text) do
      text when is_binary(text) -> {:ok, text}
      _ -> File.read(canonical_path)
    end
  end

  defp infer_language_id(path) do
    case path |> Path.extname() |> String.downcase() do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".ts" -> "typescript"
      ".tsx" -> "typescriptreact"
      ".js" -> "javascript"
      ".mjs" -> "javascript"
      ".cjs" -> "javascript"
      ".jsx" -> "javascriptreact"
      ".py" -> "python"
      ".go" -> "go"
      ".rs" -> "rust"
      ".json" -> "json"
      ".md" -> "markdown"
      _ -> "plaintext"
    end
  end

  defp maybe_put_params(payload, nil), do: payload
  defp maybe_put_params(payload, params), do: Map.put(payload, "params", params)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp safe_port_command(port, iodata) do
    if Port.info(port) != nil do
      true = Port.command(port, iodata)
      :ok
    else
      {:error, :port_closed}
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp mark_port_exited(%{exited: nil} = state, reason) do
    notify_parent_exit(state.notify_parent, {:lsp_server_exited, reason})
    fail_all(%{state | exited: reason}, {:lsp_server_exited, reason})
  end

  defp mark_port_exited(state, _reason), do: state

  defp close_port(port, os_pid, exited) do
    live_os_pid = port_os_pid(port) || if(is_nil(exited), do: os_pid, else: nil)

    if is_port(port) and Port.info(port) != nil do
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end

    if is_integer(live_os_pid) and live_os_pid > 0 and match?({:unix, _}, :os.type()) do
      kill_bin = System.find_executable("kill") || "/bin/kill"

      try do
        _ =
          System.cmd(kill_bin, ["-TERM", Integer.to_string(live_os_pid)], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp port_os_pid(_other), do: nil

  defp notify_parent_exit(pid, reason) when is_pid(pid),
    do: send(pid, {:lsp_client_exited, self(), reason})

  defp notify_parent_exit(_other, _reason), do: :ok

  defp notify_parent_message(pid, msg) when is_pid(pid),
    do: send(pid, {:lsp_notification, self(), msg})

  defp notify_parent_message(_other, _msg), do: :ok

  defp resolve_timeout(timeout, _default) when is_integer(timeout) and timeout > 0, do: timeout

  defp resolve_timeout(opts, default) when is_list(opts) do
    case Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default
    end
  end

  defp resolve_timeout(_other, default), do: default

  defp normalize_max_buffer(bytes) when is_integer(bytes) and bytes > 0, do: bytes
  defp normalize_max_buffer(bytes) when is_integer(bytes) and bytes <= 0, do: 1
  defp normalize_max_buffer(_other), do: @max_buffer_bytes

  defp open_stdio_port(executable, args, env, cd) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: Enum.map(args, &to_string/1),
        env: format_port_env(env),
        cd: to_charlist(cd)
      ])

    {:ok, port}
  rescue
    error in ArgumentError -> {:error, {:lsp_port_open, Exception.message(error)}}
  end

  defp format_port_env(env) when is_map(env) or is_list(env) do
    Enum.map(env, fn
      {k, nil} -> {String.to_charlist(to_string(k)), false}
      {k, false} -> {String.to_charlist(to_string(k)), false}
      {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp format_port_env(_other), do: []

  defp resolve_executable(command) when is_binary(command) do
    if String.contains?(command, "/") do
      if File.exists?(command), do: {:ok, command}, else: {:error, {:lsp_no_command, command}}
    else
      case System.find_executable(command) do
        nil -> {:error, {:lsp_no_command, command}}
        path -> {:ok, path}
      end
    end
  end

  defp resolve_executable(_command), do: {:error, :lsp_bad_command}
end
