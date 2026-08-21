defmodule IexCode.Projects do
  @moduledoc """
  Context for managing workspace projects.
  """
  import Ecto.Query, warn: false
  require Logger
  alias IexCode.Repo
  alias IexCode.Projects.Project

  def list_projects do
    Project
    |> order_by([p], desc: coalesce(p.last_opened_at, p.inserted_at))
    |> Repo.all()
  end

  def get_project!(id), do: Repo.get!(Project, id)

  def get_project_by_path(path) do
    Repo.get_by(Project, root_path: Path.expand(path))
  end

  @doc """
  Returns the project for the given workspace path, creating it if needed.
  On DB failure returns `{:error, reason}` — never an unsaved struct.
  """
  def get_or_create_project(path, name \\ nil) do
    expanded = Path.expand(path)
    project_name = name || Path.basename(expanded)

    case get_project_by_path(expanded) do
      %Project{} = project ->
        touch_project(project)
        {:ok, project}

      nil ->
        case create_project(%{
               name: project_name,
               root_path: expanded,
               last_opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
             }) do
          {:ok, p} ->
            {:ok, p}

          # Lost an insert race (unique root_path): another process won it.
          {:error, %Ecto.Changeset{} = changeset} ->
            case get_project_by_path(expanded) do
              %Project{} = p ->
                {:ok, p}

              nil ->
                Logger.error(
                  "Projects.get_or_create_project failed for #{expanded}: #{inspect(changeset.errors)}"
                )

                {:error, changeset}
            end

          {:error, reason} ->
            Logger.error(
              "Projects.get_or_create_project failed for #{expanded}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error("Projects.get_or_create_project failed: #{Exception.message(e)}")
      {:error, {:db_error, Exception.message(e)}}
  end

  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  def touch_project(%Project{} = project) do
    update_project(project, %{
      last_opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end
end
