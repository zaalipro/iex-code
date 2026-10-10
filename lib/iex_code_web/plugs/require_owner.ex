defmodule IexCodeWeb.Plugs.RequireOwner do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn
  alias IexCode.OwnerAuth
  alias IexCodeWeb.Plugs.LocalAccess

  def init(opts), do: opts

  def call(conn, _opts) do
    case authorization(conn) do
      :ok -> conn
      :unavailable -> deny(conn, 503)
      :denied -> conn |> Phoenix.Controller.redirect(to: "/login") |> halt()
    end
  end

  def transport(conn) do
    conn =
      conn
      |> Plug.Session.call(Plug.Session.init(IexCodeWeb.Endpoint.session_options()))
      |> fetch_session()

    case authorization(conn) do
      :ok -> conn
      :unavailable -> deny(conn, 503)
      :denied -> deny(conn, 403)
    end
  end

  def authorization(conn) do
    case OwnerAuth.mode() do
      :local ->
        if LocalAccess.local_request?(conn.remote_ip, conn.host), do: :ok, else: :denied

      :remote ->
        if OwnerAuth.session_valid?(get_session(conn)), do: :ok, else: :denied

      :unavailable ->
        :unavailable
    end
  end

  defp deny(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, if(status == 503, do: "unavailable", else: "forbidden"))
    |> halt()
  end
end
