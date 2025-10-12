defmodule JumpstartAiWeb.ChatLive do
  use Elixir.JumpstartAiWeb, :live_view
  on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_required}

  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-full bg-white overflow-hidden">
      <!-- Main Content Area -->
      <div class="flex-1 flex flex-col">
        <!-- Header -->
        <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200">
          <h1 class="text-2xl font-semibold text-gray-900">Ask Anything</h1>
          <.link navigate={~p"/"} class="text-gray-400 hover:text-gray-600" aria-label="Close">
            <.icon name="hero-x-mark" class="w-6 h-6" />
          </.link>
        </div>
        
    <!-- Tabs -->
        <div class="flex items-center justify-between px-6 border-b border-gray-200">
          <div class="flex gap-8">
            <button
              phx-click="switch_tab"
              phx-value-tab="chat"
              class={[
                "py-3 text-base font-medium border-b-2 transition-colors",
                (@active_tab == :chat && "border-black text-black") ||
                  "border-transparent text-gray-500"
              ]}
            >
              Chat
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="history"
              class={[
                "py-3 text-base font-medium border-b-2 transition-colors",
                (@active_tab == :history && "border-black text-black") ||
                  "border-transparent text-gray-500"
              ]}
            >
              History
            </button>
          </div>
          <button
            phx-click="new_thread"
            class="flex items-center gap-2 text-sm font-medium text-gray-900 hover:text-gray-700"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> New thread
          </button>
        </div>
        
    <!-- Context Display -->
        <div class="px-6 py-4 border-b border-gray-200">
          <div class="flex items-center justify-center gap-4 max-w-3xl mx-auto">
            <div class="flex-1 h-px bg-gray-200"></div>
            <div class="text-center">
              <p class="text-sm text-gray-600">{@context_description}</p>
              <p class="text-xs text-gray-400 mt-1">
                {Calendar.strftime(DateTime.utc_now(), "%I:%M%P - %B %d, %Y")}
              </p>
            </div>
            <div class="flex-1 h-px bg-gray-200"></div>
          </div>
        </div>
        
    <!-- Messages Area -->
        <div class="flex-1 overflow-y-auto px-6 py-8">
          <div :if={@active_tab == :chat}>
            <!-- Chat Tab Content -->
            <div :if={@conversation}>
              <div id="message-container" phx-update="stream" class="space-y-6 max-w-3xl mx-auto">
                <div :for={{id, message} <- @streams.messages} id={id}>
                  <div :if={message.source == :agent} class="space-y-4">
                    <!-- Agent Message -->
                    <div class="text-[15px] text-gray-900 leading-[1.6]">
                      <.markdown text={message.text} />
                    </div>
                  </div>
                  <div
                    :if={message.source != :agent}
                    class="bg-gray-100 rounded-2xl px-5 py-4 inline-block max-w-2xl"
                  >
                    <!-- User Message (Suggestion Card Style) -->
                    <div class="text-[15px] text-gray-900 leading-[1.5]">
                      <.markdown text={message.text} />
                    </div>
                  </div>
                </div>
              </div>
              
    <!-- Thinking Indicator -->
              <div :if={@thinking} class="max-w-3xl mx-auto mt-6">
                <div class="flex items-center gap-2 text-gray-500">
                  <span class="loading loading-dots loading-sm"></span>
                  <span class="text-sm">Thinking...</span>
                </div>
              </div>
            </div>
            <div :if={!@conversation} class="max-w-3xl mx-auto text-center py-12">
              <p class="text-gray-500 text-lg">Start a new conversation</p>
              <p class="text-gray-400 text-sm mt-2">Type your question below to begin</p>
            </div>
          </div>
          <div :if={@active_tab == :history}>
            <!-- History Tab Content -->
            <div class="max-w-5xl mx-auto">
              <div
                :if={@has_conversations}
                id="conversation-list"
                phx-update="stream"
                class="space-y-3"
              >
                <div :for={{id, conversation} <- @streams.conversations} id={id}>
                  <button
                    phx-click="select_conversation"
                    phx-value-id={conversation.id}
                    class="w-full text-left px-4 py-3 rounded-lg hover:bg-gray-50 border border-gray-200 transition-colors"
                  >
                    <div class="font-medium text-gray-900">
                      {build_conversation_title_string(conversation.title)}
                    </div>
                    <div class="text-sm text-gray-500 mt-1">
                      {Calendar.strftime(conversation.inserted_at, "%B %d, %Y at %I:%M %p")}
                    </div>
                  </button>
                </div>
              </div>
              <div :if={!@has_conversations} class="text-gray-500 text-center py-8">
                <p class="text-lg">Conversation history will appear here</p>
                <p class="text-sm mt-2">
                  Your past conversations and search history will be displayed in this section
                </p>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Input Area -->
        <div class="border-t border-gray-200 px-6 py-4">
          <div class="max-w-3xl mx-auto">
            <.form
              :let={form}
              for={@message_form}
              phx-change="validate_message"
              phx-debounce="blur"
              phx-submit="send_message"
              class="relative"
            >
              <textarea
                name={form[:text].name}
                value={form[:text].value}
                phx-mounted={JS.focus()}
                placeholder="Ask anything about your meetings..."
                rows="3"
                class="w-full px-4 py-3 pr-32 border border-gray-300 rounded-xl resize-none focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
              ></textarea>
              
    <!-- Action Buttons Row -->
              <div class="flex items-center justify-between mt-3">
                <div class="flex items-center gap-2">
                  <!-- Add Button -->
                  <button
                    type="button"
                    class="w-10 h-10 flex items-center justify-center rounded-full border border-gray-300 hover:bg-gray-50"
                  >
                    <.icon name="hero-plus" class="w-5 h-5 text-gray-600" />
                  </button>
                  
    <!-- Context Selector -->
                  <div class="relative">
                    <select
                      phx-change="change_context"
                      name="context"
                      class="pl-4 pr-10 py-2 border border-gray-300 rounded-full text-sm appearance-none bg-white hover:bg-gray-50 cursor-pointer"
                    >
                      <option value="all_meetings" selected={@context_type == "all_meetings"}>
                        All meetings
                      </option>
                      <option value="all_contacts" selected={@context_type == "all_contacts"}>
                        All contacts
                      </option>
                      <option value="all_emails" selected={@context_type == "all_emails"}>
                        All emails
                      </option>
                    </select>
                  </div>
                  
    <!-- Calendar Button -->
                  <button
                    type="button"
                    class="w-10 h-10 flex items-center justify-center rounded-full bg-red-100 hover:bg-red-200"
                  >
                    <.icon name="hero-calendar" class="w-5 h-5 text-red-600" />
                  </button>
                  
    <!-- Location Button -->
                  <button
                    type="button"
                    class="w-10 h-10 flex items-center justify-center rounded-full bg-blue-100 hover:bg-blue-200"
                  >
                    <.icon name="hero-map-pin" class="w-5 h-5 text-blue-600" />
                  </button>
                </div>
                
    <!-- Microphone Button -->
                <button
                  type="button"
                  class="w-10 h-10 flex items-center justify-center rounded-full hover:bg-gray-100"
                >
                  <.icon name="hero-microphone" class="w-5 h-5 text-gray-600" />
                </button>
              </div>
            </.form>
          </div>
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

    conversations =
      JumpstartAi.Chat.my_conversations!(
        actor: socket.assigns.current_user,
        query: [sort: [inserted_at: :desc]]
      )

    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:skip_layout, true)
      |> assign(:thinking, false)
      |> assign(:active_tab, :chat)
      |> assign(:context_type, "all_meetings")
      |> assign(:context_description, "Context set to all meetings")
      |> assign(:has_conversations, length(conversations) > 0)
      |> assign(:conversations_list, conversations)
      |> assign(:conversation, nil)
      |> stream_configure(:conversations, dom_id: &"conversations-#{&1.id}")
      |> stream(:conversations, conversations)
      |> stream_configure(:messages, dom_id: &"messages-#{&1.id}")
      |> stream(:messages, [])
      |> assign_message_form()

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

    # Check if conversations_list is set, if not, set it to empty
    socket =
      if Map.has_key?(socket.assigns, :conversations_list) do
        socket
      else
        assign(socket, :conversations_list, [])
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
    {:noreply,
     socket
     |> assign(:active_tab, :chat)
     |> push_navigate(to: ~p"/chat/#{conversation_id}")}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)

    # If switching to history tab, reset and re-stream conversations
    socket =
      if tab_atom == :history do
        conversations = socket.assigns.conversations_list || []

        socket
        |> stream(:conversations, conversations, reset: true)
      else
        socket
      end

    # If switching to chat tab and we have a conversation, ensure we're on the right URL
    socket =
      if tab_atom == :chat && socket.assigns.conversation do
        push_navigate(socket, to: ~p"/chat/#{socket.assigns.conversation.id}")
      else
        socket
      end

    {:noreply, assign(socket, :active_tab, tab_atom)}
  end

  def handle_event("new_thread", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/chat")}
  end

  def handle_event("change_context", %{"context" => context}, socket) do
    description =
      case context do
        "all_meetings" -> "Context set to all meetings"
        "all_contacts" -> "Context set to all contacts"
        "all_emails" -> "Context set to all emails"
        _ -> "Context set to all meetings"
      end

    socket =
      socket
      |> assign(:context_type, context)
      |> assign(:context_description, description)

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:messages:" <> conversation_id,
          payload: %{source: source, complete: complete, id: _id} = message
        },
        socket
      ) do
    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      cond do
        source == :user ->
          # User message received - show thinking indicator
          socket =
            socket
            |> stream_insert(:messages, message, at: 0)
            |> assign(:thinking, true)

          {:noreply, socket}

        source == :agent && complete == false ->
          # Agent started responding - hide thinking indicator
          socket =
            socket
            |> stream_insert(:messages, message, at: 0)
            |> assign(:thinking, false)

          {:noreply, socket}

        source == :agent && complete == true ->
          socket =
            socket
            |> stream_insert(:messages, message, at: 0)
            |> assign(:thinking, false)

          {:noreply, socket}

        true ->
          {:noreply, stream_insert(socket, :messages, message, at: 0)}
      end
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

    {:noreply,
     socket |> stream_insert(:conversations, conversation) |> assign(:has_conversations, true)}
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
