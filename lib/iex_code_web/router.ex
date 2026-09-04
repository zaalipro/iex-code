defmodule IexCodeWeb.Router do
  use IexCodeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug IexCodeWeb.Plugs.LocalAccess
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IexCodeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", IexCodeWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
    live "/research", WorkspaceLive, :research
    live "/settings", SettingsLive, :index
    live "/settings/:tab", SettingsLive, :tab
    live "/sessions/:id", WorkspaceLive, :show
    live "/sessions/:id/research", WorkspaceLive, :research
    live "/sessions/:id/settings", SettingsLive, :session
    live "/sessions/:id/settings/:tab", SettingsLive, :session_tab

    get "/research/:id/report", ResearchReportController, :show
    get "/research/:id/report/download", ResearchReportController, :download_html
    get "/research/:id/result/download", ResearchReportController, :download_markdown

    scope "/sessions/:id/detached", Detached, as: :detached do
      live "/terminal", TerminalLive, :show
      live "/diff", DiffLive, :show
      live "/dag", DagLive, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", IexCodeWeb do
  #   pipe_through :api
  # end
end
