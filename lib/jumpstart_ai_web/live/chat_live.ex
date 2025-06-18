defmodule JumpstartAiWeb.ChatLive do
  use Elixir.JumpstartAiWeb, :live_view
  on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_required}

  def render(assigns) do
    ~H"""
    <div class="drawer md:drawer-open bg-base-200 min-h-screen h-screen w-screen fixed inset-0">
      <input id="ash-ai-drawer" type="checkbox" class="drawer-toggle" />
      <div class="drawer-content flex flex-col min-h-screen">
        <div class="navbar bg-base-300 w-full">
          <div class="flex-none md:hidden">
            <label for="ash-ai-drawer" aria-label="open sidebar" class="btn btn-square btn-ghost">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                class="inline-block h-6 w-6 stroke-current"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 6h16M4 12h16M4 18h16"
                >
                </path>
              </svg>
            </label>
          </div>
          <img src={~p"/images/logo.svg"} alt="Logo" class="h-12" height="48" />
          <div class="mx-2 flex-1 px-2">
            <p :if={@conversation} class="text-lg font-medium">
              {build_conversation_title_string(@conversation.title)}
            </p>
            <p class="text-sm">JumpstartAI</p>
          </div>
        </div>
        <div class="flex-1 flex flex-col overflow-hidden bg-base-200">
          <div
            id="message-container"
            phx-update="stream"
            class="flex-1 overflow-y-auto px-4 py-2 flex flex-col-reverse"
          >
            <%= for {id, message} <- @streams.messages do %>
              <div
                id={id}
                class={[
                  "chat",
                  message.source == :user && "chat-end",
                  message.source == :agent && "chat-start"
                ]}
              >
                <div :if={message.source == :agent} class="chat-image avatar">
                  <div class="w-10 rounded-full bg-base-300 p-1">
                    <img
                      src="https://github.com/ash-project/ash_ai/blob/main/logos/ash_ai.png?raw=true"
                      alt="Logo"
                    />
                  </div>
                </div>
                <div :if={message.source == :user} class="chat-image avatar avatar-placeholder">
                  <div class="w-10 rounded-full bg-base-300">
                    <.icon name="hero-user-solid" class="block" />
                  </div>
                </div>
                <div class="chat-bubble text-lg leading-relaxed">
                  <.markdown text={message.text} />
                </div>
              </div>
            <% end %>
          </div>
        </div>
        <div class="p-4 border-t border-base-300 bg-base-200 flex-shrink-0">
          <.form
            :let={form}
            for={@message_form}
            phx-change="validate_message"
            phx-debounce="blur"
            phx-submit="send_message"
            class="flex items-center gap-4"
          >
            <div class="flex-1">
              <input
                name={form[:text].name}
                value={form[:text].value}
                type="text"
                phx-mounted={JS.focus()}
                placeholder="Type your message..."
                class="input input-primary w-full mb-0 text-lg"
                autocomplete="off"
              />
            </div>
            <button type="submit" class="btn btn-primary rounded-full text-lg">
              <.icon name="hero-paper-airplane" /> Send
            </button>
          </.form>
        </div>
      </div>

      <div class="drawer-side border-r border-base-content/20 bg-base-300 w-72 h-full">
        <div class="py-4 px-6">
          <.header class="text-xl mb-4 font-semibold">
            Conversations
          </.header>
          <div class="mb-4">
            <.link navigate={~p"/chat"} class="btn btn-primary btn-lg mb-2">
              <div class="rounded-full bg-primary-content text-primary w-6 h-6 flex items-center justify-center">
                <.icon name="hero-plus" />
              </div>
              <span>New Chat</span>
            </.link>
          </div>
          <ul class="flex flex-col-reverse" phx-update="stream" id="conversations-list">
            <%= for {id, conversation} <- @streams.conversations do %>
              <li id={id}>
                <.link
                  href={~p"/chat/#{conversation.id}"}
                  phx-click="select_conversation"
                  phx-value-id={conversation.id}
                  class={"block py-2 px-3 transition border-l-4 pl-2 mb-2 text-lg #{if @conversation && @conversation.id == conversation.id, do: "border-primary font-medium", else: "border-transparent"}"}
                >
                  {build_conversation_title_string(conversation.title)}
                </.link>
              </li>
            <% end %>
          </ul>
        </div>
        <div class="absolute bottom-4 left-4 flex flex-col gap-2">
          <.link navigate="/settings" class="btn btn-ghost btn-sm">
            <.icon name="hero-cog-6-tooth" /> Settings
          </.link>
          <a href="/sign-out" class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-right-on-rectangle" /> Sign Out
          </a>
        </div>
      </div>
    </div>
    """
  end

  def build_conversation_title_string(title) do
    cond do
      title == nil -> "Untitled conversation"
      is_binary(title) && String.length(title) > 25 -> String.slice(title, 0, 25) <> "..."
      is_binary(title) && String.length(title) <= 25 -> title
    end
  end

  def mount(_params, _session, socket) do
    JumpstartAiWeb.Endpoint.subscribe("chat:conversations:#{socket.assigns.current_user.id}")

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> stream(
        :conversations,
        JumpstartAi.Chat.my_conversations!(actor: socket.assigns.current_user)
      )
      |> assign(:messages, [])

    {:ok, socket}
  end

  def handle_params(%{"conversation_id" => conversation_id}, _, socket) do
    conversation =
      JumpstartAi.Chat.get_conversation!(conversation_id, actor: socket.assigns.current_user)

    cond do
      socket.assigns[:conversation] && socket.assigns[:conversation].id == conversation.id ->
        :ok

      socket.assigns[:conversation] ->
        JumpstartAiWeb.Endpoint.unsubscribe("chat:messages:#{socket.assigns.conversation.id}")
        JumpstartAiWeb.Endpoint.subscribe("chat:messages:#{conversation.id}")

      true ->
        JumpstartAiWeb.Endpoint.subscribe("chat:messages:#{conversation.id}")
    end

    socket
    |> assign(:conversation, conversation)
    |> stream(:messages, JumpstartAi.Chat.message_history!(conversation.id, stream?: true))
    |> assign_message_form()
    |> then(&{:noreply, &1})
  end

  def handle_params(_, _, socket) do
    if socket.assigns[:conversation] do
      JumpstartAiWeb.Endpoint.unsubscribe("chat:messages:#{socket.assigns.conversation.id}")
    end

    socket
    |> assign(:conversation, nil)
    |> stream(:messages, [])
    |> assign_message_form()
    |> then(&{:noreply, &1})
  end

  def handle_event("validate_message", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :message_form, AshPhoenix.Form.validate(socket.assigns.message_form, params))}
  end

  def handle_event("send_message", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.message_form, params: params) do
      {:ok, message} ->
        if socket.assigns.conversation do
          socket
          |> assign_message_form()
          |> stream_insert(:messages, message, at: 0)
          |> then(&{:noreply, &1})
        else
          {:noreply,
           socket
           |> push_navigate(to: ~p"/chat/#{message.conversation_id}")}
        end

      {:error, form} ->
        {:noreply, assign(socket, :message_form, form)}
    end
  end

  def handle_event("select_conversation", %{"id" => conversation_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation_id}")}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:messages:" <> conversation_id,
          payload: message
        },
        socket
      ) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      {:noreply, stream_insert(socket, :messages, message, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:conversations:" <> _,
          payload: conversation
        },
        socket
      ) do
    socket =
      if socket.assigns.conversation && socket.assigns.conversation.id == conversation.id do
        assign(socket, :conversation, conversation)
      else
        socket
      end

    {:noreply, stream_insert(socket, :conversations, conversation)}
  end

  defp assign_message_form(socket) do
    form =
      if socket.assigns.conversation do
        JumpstartAi.Chat.form_to_create_message(
          actor: socket.assigns.current_user,
          private_arguments: %{conversation_id: socket.assigns.conversation.id}
        )
        |> to_form()
      else
        JumpstartAi.Chat.form_to_create_message(actor: socket.assigns.current_user)
        |> to_form()
      end

    assign(
      socket,
      :message_form,
      form
    )
  end
end
