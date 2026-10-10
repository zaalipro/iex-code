defmodule IexCodeWeb.HealthController do
  use IexCodeWeb, :controller

  def ready(conn, _params) do
    ready = IexCode.OwnerAuth.ready?()

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(if(ready, do: 200, else: 503), if(ready, do: "ok", else: "unavailable"))
  end
end
