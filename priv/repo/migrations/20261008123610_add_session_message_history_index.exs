defmodule IexCode.Repo.Migrations.AddSessionMessageHistoryIndex do
  use Ecto.Migration

  def change do
    create index(:messages, [:session_id, :inserted_at, :id])
  end
end
