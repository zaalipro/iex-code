defmodule IexCodeWeb.OwnerAuth do
  @moduledoc false
  import Phoenix.LiveView
  alias IexCode.OwnerAuth
  alias IexCodeWeb.Plugs.LocalAccess

  @idle_ms 30_000

  def on_mount(:require_owner, _params, session, socket) do
    peer = get_connect_info(socket, :peer_data)
    uri = get_connect_info(socket, :uri)
    local = LocalAccess.local_request?(peer && peer.address, uri && uri.host)
    socket = put_in(socket.private[:owner_auth], %{session: session, local: local})

    if authorized?(socket) do
      socket =
        socket
        |> attach_hook(:owner_auth_event, :handle_event, fn _, _, socket -> guard(socket) end)
        |> attach_hook(:owner_auth_params, :handle_params, fn _, _, socket -> guard(socket) end)
        |> attach_hook(:owner_auth_info, :handle_info, &guard_info/2)

      if connected?(socket), do: schedule_check(socket)
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  defp authorized?(socket) do
    case OwnerAuth.mode() do
      :local -> socket.private.owner_auth.local
      :remote -> OwnerAuth.session_valid?(socket.private.owner_auth.session)
      :unavailable -> false
    end
  end

  defp guard(socket) do
    if authorized?(socket), do: {:cont, socket}, else: {:halt, redirect(socket, to: "/login")}
  end

  defp guard_info(:owner_auth_tick, socket) do
    if authorized?(socket) do
      schedule_check(socket)
      {:halt, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  defp guard_info(_message, socket), do: guard(socket)

  defp schedule_check(socket) do
    remaining =
      if OwnerAuth.mode() == :local,
        do: @idle_ms,
        else: OwnerAuth.remaining_ms(socket.private.owner_auth.session)

    Process.send_after(self(), :owner_auth_tick, max(1, min(@idle_ms, remaining)))
  end
end
