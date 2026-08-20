defmodule IexCode.Repo do
  use Ecto.Repo,
    otp_app: :iex_code,
    adapter: Ecto.Adapters.SQLite3
end
