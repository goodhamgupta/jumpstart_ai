defmodule JumpstartAiWeb.PageController do
  use JumpstartAiWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def sign_in(conn, _params) do
    # Check if user is already authenticated
    if conn.assigns[:current_user] do
      redirect(conn, to: "/chat")
    else
      redirect(conn, to: "/sign-in")
    end
  end
end
