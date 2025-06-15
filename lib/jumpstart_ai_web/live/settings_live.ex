defmodule JumpstartAiWeb.SettingsLive do
  use JumpstartAiWeb, :live_view

  on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:hubspot_connected?, is_hubspot_connected?(user))}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Refresh user data in case they just completed OAuth
    require Ash.Query
    current_user = socket.assigns.current_user
    user_id = current_user.id

    refreshed_user =
      case JumpstartAi.Accounts.User
           |> Ash.Query.filter(id == ^user_id)
           |> Ash.read_one() do
        {:ok, user} -> user
        {:error, _} -> current_user
      end

    {:noreply,
     socket
     |> assign(:hubspot_connected?, is_hubspot_connected?(refreshed_user))}
  end

  @impl true
  def handle_event("connect_hubspot", _params, socket) do
    # Redirect to HubSpot OAuth flow
    hubspot_auth_url = "/auth/user/hubspot"
    {:noreply, redirect(socket, external: hubspot_auth_url)}
  end

  @impl true
  def handle_event("disconnect_hubspot", _params, socket) do
    user = socket.assigns.current_user

    case user
         |> Ash.Changeset.for_update(:update, %{
           hubspot_access_token: nil,
           hubspot_refresh_token: nil,
           hubspot_token_expires_at: nil,
           hubspot_portal_id: nil
         })
         |> Ash.update() do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:hubspot_connected?, false)
         |> put_flash(:info, "HubSpot account disconnected successfully")}

      {:error, _error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to disconnect HubSpot account")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen bg-gray-50 flex flex-col">
      <div class="flex-1 max-w-4xl mx-auto py-4 px-4 sm:px-6 lg:px-8">
        <div class="flex items-center justify-between mb-4">
          <div class="min-w-0 flex-1">
            <h2 class="text-2xl font-bold leading-7 text-gray-900">
              Account Settings
            </h2>
            <p class="mt-1 text-sm text-gray-500">
              Manage your account connections and preferences
            </p>
          </div>
          <div class="flex ml-4">
            <.link
              navigate="/chat"
              class="inline-flex items-center rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 hover:bg-gray-50"
            >
              ← Back to Chat
            </.link>
          </div>
        </div>

        <div>
          <div class="bg-white shadow sm:rounded-lg">
            <div class="px-4 py-4 sm:p-4">
              <h3 class="text-base font-semibold leading-6 text-gray-900">
                Connected Accounts
              </h3>
              <div class="mt-1 max-w-xl text-sm text-gray-500">
                <p>Connect your accounts to enable AI-powered automation and data access.</p>
              </div>

              <div class="mt-4 space-y-4">
                <!-- Google Account (Always Connected) -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center">
                    <div class="flex-shrink-0">
                      <svg class="h-8 w-8" viewBox="0 0 24 24">
                        <path
                          fill="#4285F4"
                          d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                        />
                        <path
                          fill="#34A853"
                          d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                        />
                        <path
                          fill="#FBBC05"
                          d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                        />
                        <path
                          fill="#EA4335"
                          d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                        />
                      </svg>
                    </div>
                    <div class="ml-4">
                      <div class="text-sm font-medium text-gray-900">Google Account</div>
                      <div class="text-sm text-gray-500">
                        {if @current_user, do: @current_user.email, else: "Loading..."}
                      </div>
                    </div>
                  </div>
                  <div class="flex items-center">
                    <span class="inline-flex items-center rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800">
                      Connected
                    </span>
                  </div>
                </div>
                
    <!-- HubSpot Account -->
                <div class="flex items-center justify-between">
                  <div class="flex items-center">
                    <div class="flex-shrink-0">
                      <svg class="h-8 w-8" viewBox="0 0 24 24">
                        <path
                          fill="#FF7A59"
                          d="M18.164 7.93V5.084a3.244 3.244 0 1 0-1.607 0V7.93a5.75 5.75 0 0 0-2.858 2.542L10.938 8.85a2.681 2.681 0 1 0-1.104.946l2.76 1.622a5.719 5.719 0 0 0-.015 1.164L9.834 14.2a2.682 2.682 0 1 0 1.104.946l2.745-1.618a5.75 5.75 0 1 0 4.48-5.598zm-8.98 8.924a.866.866 0 1 1-.866-.866.866.866 0 0 1 .866.866zm8.164-12.77a1.607 1.607 0 1 1-1.607 1.607 1.607 1.607 0 0 1 1.607-1.607zm0 15.832a4.114 4.114 0 1 1 4.114-4.114 4.114 4.114 0 0 1-4.114 4.114z"
                        />
                      </svg>
                    </div>
                    <div class="ml-4">
                      <div class="text-sm font-medium text-gray-900">HubSpot CRM</div>
                      <div class="text-sm text-gray-500">
                        Access contacts & notes from your HubSpot account
                      </div>
                    </div>
                  </div>
                  <div class="flex items-center space-x-3">
                    <%= if @hubspot_connected? do %>
                      <span class="inline-flex items-center rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800">
                        Connected
                      </span>
                      <button
                        phx-click="disconnect_hubspot"
                        class="inline-flex items-center rounded-md bg-red-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-red-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-600"
                      >
                        Disconnect
                      </button>
                    <% else %>
                      <button
                        phx-click="connect_hubspot"
                        class="inline-flex items-center rounded-md bg-orange-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-orange-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-orange-600"
                      >
                        Connect
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp is_hubspot_connected?(nil), do: false

  defp is_hubspot_connected?(user) do
    not is_nil(user.hubspot_access_token)
  end
end
