defmodule IexCode.Repo do
  use Ecto.Repo,
    otp_app: :iex_code,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Executes a function with exponential backoff retry on SQLite busy/locked errors.
  """
  def retry_on_busy(fun, attempts \\ 10, delay_ms \\ 25) do
    fun.()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      msg = Exception.message(e)

      if attempts > 1 and
           (String.contains?(String.downcase(msg), "busy") or
              String.contains?(String.downcase(msg), "locked")) do
        Process.sleep(delay_ms)
        retry_on_busy(fun, attempts - 1, delay_ms * 2)
      else
        reraise e, __STACKTRACE__
      end
  end
end
