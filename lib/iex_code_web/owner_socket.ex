defmodule IexCodeWeb.OwnerSocket do
  @moduledoc false
  use Phoenix.LiveView.Socket

  # Phoenix marks missing/invalid native handshake CSRF as a nil session.
  # Stock LiveView defers its rejection until channel join. Reject the
  # handshake itself; the endpoint still gates every longpoll resume.
  def connect(_params, socket, %{session: session} = info) when is_map(session) do
    allowed =
      case IexCode.OwnerAuth.mode() do
        :remote ->
          IexCode.OwnerAuth.session_valid?(session)

        :local ->
          peer = info[:peer_data]
          uri = info[:uri]
          IexCodeWeb.Plugs.LocalAccess.local_request?(peer && peer.address, uri && uri.host)

        :unavailable ->
          false
      end

    if allowed, do: {:ok, socket}, else: :error
  end

  def connect(_params, _socket, _info), do: :error
end
