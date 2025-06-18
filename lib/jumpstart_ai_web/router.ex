defmodule JumpstartAiWeb.Router do
  use JumpstartAiWeb, :router

  import Oban.Web.Router
  use AshAuthentication.Phoenix.Router
  import Plug.BasicAuth

  import AshAuthentication.Plug.Helpers
  require Logger

  # Custom plug to log auth requests
  defp log_auth_requests(conn, _opts) do
    if String.starts_with?(conn.request_path, "/auth") do
      Logger.info("Auth Route Request - Path: #{conn.request_path}")
      Logger.info("Auth Route Request - Method: #{conn.method}")
      Logger.info("Auth Route Request - Query Params: #{inspect(conn.query_params)}")

      Logger.info(
        "Auth Route Request - Full URL: #{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
      )
    end

    conn
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JumpstartAiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug :log_auth_requests
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  pipeline :oban_auth do
    plug :basic_auth,
      username: System.get_env("OBAN_USERNAME") || "admin",
      password: System.get_env("OBAN_PASSWORD") || "secret"
  end

  scope "/", JumpstartAiWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      live "/chat", ChatLive
      live "/chat/:conversation_id", ChatLive
      live "/settings", SettingsLive
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {JumpstartAiWeb.LiveUserAuth, :live_no_user}
    end
  end

  scope "/", JumpstartAiWeb do
    pipe_through :browser

    get "/", PageController, :sign_in
    auth_routes AuthController, JumpstartAi.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Remove these if you'd like to use your own authentication views
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{JumpstartAiWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    JumpstartAiWeb.AuthOverrides,
                    AshAuthentication.Phoenix.Overrides.Default
                  ],
                  sign_in_path: "/sign-in",
                  success_redirect_path: "/chat"

    # Remove this if you do not want to use the reset password feature
    reset_route auth_routes_prefix: "/auth",
                overrides: [
                  JumpstartAiWeb.AuthOverrides,
                  AshAuthentication.Phoenix.Overrides.Default
                ]

    # Remove this if you do not use the confirmation strategy
    confirm_route JumpstartAi.Accounts.User, :confirm_new_user,
      auth_routes_prefix: "/auth",
      overrides: [JumpstartAiWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    # Remove this if you do not use the magic link strategy.
    magic_sign_in_route(JumpstartAi.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      overrides: [JumpstartAiWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]
    )
  end

  # Other scopes may use custom stacks.
  # scope "/api", JumpstartAiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:jumpstart_ai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: JumpstartAiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Oban Dashboard with basic auth protection (available in all environments)
  scope "/" do
    pipe_through [:browser, :oban_auth]

    oban_dashboard("/oban")
  end
end
