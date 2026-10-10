defmodule IexCodeWeb.OwnerSessionController do
  use IexCodeWeb, :controller
  alias IexCode.OwnerAuth

  plug :put_root_layout, html: {IexCodeWeb.Layouts, :public}
  plug :put_layout, false
  plug :no_store

  def new(conn, _params), do: render(conn, :new, error: nil)

  def create(conn, params) do
    owner = Map.get(params, "owner", %{})
    owner = if is_map(owner), do: owner, else: %{}

    case OwnerAuth.login(owner["username"], owner["password"]) do
      {:ok, session} ->
        conn = renew(conn)

        conn =
          Enum.reduce(session, conn, fn {key, value}, acc -> put_session(acc, key, value) end)

        redirect(conn, to: "/")

      {:error, :throttled, retry} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", Integer.to_string(retry))
        |> render(:new, error: "Try again shortly.")

      {:error, :unavailable} ->
        conn |> put_status(503) |> render(:new, error: "unavailable")

      {:error, :invalid_credentials} ->
        conn |> put_status(401) |> render(:new, error: "Invalid credentials.")
    end
  end

  def delete(conn, _params) do
    case OwnerAuth.logout(get_session(conn)) do
      {:ok, topic} -> IexCodeWeb.Endpoint.broadcast(topic, "disconnect", %{})
      {:error, _} -> :ok
    end

    conn |> renew() |> configure_session(drop: true) |> redirect(to: "/login")
  end

  defp renew(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> configure_session(renew: true) |> clear_session()
  end

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
end
