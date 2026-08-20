defmodule IexCode.Projects do
  @moduledoc """
  Context for managing workspace projects.
  """
  import Ecto.Query, warn: false
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

  def get_or_create_project(path, name \\ nil) do
    expanded = Path.expand(path)
    project_name = name || Path.basename(expanded)

    try do
      case get_project_by_path(expanded) do
        nil ->
          case create_project(%{
                 name: project_name,
                 root_path: expanded,
                 last_opened_at: DateTime.utc_now() |> DateTime.truncate(:second)
               }) do
            {:ok, p} ->
              {:ok, p}

            {:error, _} ->
              case get_project_by_path(expanded) do
                %Project{} = p ->
                  {:ok, p}

                _ ->
                  {:ok,
                   %Project{id: Ecto.UUID.generate(), name: project_name, root_path: expanded}}
              end
          end

        %Project{} = project ->
          touch_project(project)
          {:ok, project}
      end
    rescue
      _ ->
        {:ok, %Project{id: Ecto.UUID.generate(), name: project_name, root_path: expanded}}
    catch
      _, _ ->
        {:ok, %Project{id: Ecto.UUID.generate(), name: project_name, root_path: expanded}}
    end
  end

  def create_project(attrs \\ %{}, retries \\ 20) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      if retries > 0 do
        :timer.sleep(35)
        create_project(attrs, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
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
