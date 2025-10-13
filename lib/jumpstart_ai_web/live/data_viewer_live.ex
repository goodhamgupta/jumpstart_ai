defmodule JumpstartAiWeb.DataViewerLive do
  use JumpstartAiWeb, :live_view

  on_mount {JumpstartAiWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Database Viewer")
     |> assign(:skip_layout, true)
     |> assign(:active_tab, :contacts)
     |> assign(:contacts, [])
     |> assign(:contact_notes, [])
     |> assign(:emails, [])
     |> assign(:tasks, [])
     |> assign(:ongoing_instructions, [])
     |> assign(:loading, true)
     # Pagination state
     |> assign(:contacts_page, 1)
     |> assign(:contact_notes_page, 1)
     |> assign(:emails_page, 1)
     |> assign(:tasks_page, 1)
     |> assign(:ongoing_instructions_page, 1)
     |> assign(:page_size, 25)
     |> assign(:contacts_total, 0)
     |> assign(:contact_notes_total, 0)
     |> assign(:emails_total, 0)
     |> assign(:tasks_total, 0)
     |> assign(:ongoing_instructions_total, 0)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    active_tab = String.to_existing_atom(tab)
    {:noreply, assign(socket, :active_tab, active_tab)}
  end

  @impl true
  def handle_event("refresh_data", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_data()}
  end

  @impl true
  def handle_event("paginate", %{"table" => table, "page" => page}, socket) do
    page = String.to_integer(page)

    socket = case table do
      "contacts" -> assign(socket, :contacts_page, page)
      "contact_notes" -> assign(socket, :contact_notes_page, page)
      "emails" -> assign(socket, :emails_page, page)
      "tasks" -> assign(socket, :tasks_page, page)
      "ongoing_instructions" -> assign(socket, :ongoing_instructions_page, page)
    end

    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_data()}
  end

  defp load_data(socket) do
    user = socket.assigns.current_user
    page_size = socket.assigns.page_size

    # Load contacts with pagination
    {contacts_result, contacts_total} = load_contacts_paginated(user, socket.assigns.contacts_page, page_size)

    # Load contact notes with pagination
    {notes_result, notes_total} = load_contact_notes_paginated(user, socket.assigns.contact_notes_page, page_size)

    # Load emails with pagination
    {emails_result, emails_total} = load_emails_paginated(user, socket.assigns.emails_page, page_size)

    # Load tasks with pagination
    {tasks_result, tasks_total} = load_tasks_paginated(user, socket.assigns.tasks_page, page_size)

    # Load ongoing instructions with pagination
    {ongoing_instructions_result, ongoing_instructions_total} = load_ongoing_instructions_paginated(user, socket.assigns.ongoing_instructions_page, page_size)

    socket
    |> assign(:contacts, contacts_result)
    |> assign(:contact_notes, notes_result)
    |> assign(:emails, emails_result)
    |> assign(:tasks, tasks_result)
    |> assign(:ongoing_instructions, ongoing_instructions_result)
    |> assign(:contacts_total, contacts_total)
    |> assign(:contact_notes_total, notes_total)
    |> assign(:emails_total, emails_total)
    |> assign(:tasks_total, tasks_total)
    |> assign(:ongoing_instructions_total, ongoing_instructions_total)
    |> assign(:loading, false)
  end

  defp load_contacts_paginated(user, page, page_size) do
    offset = (page - 1) * page_size

    # Get total count
    total = case JumpstartAi.Accounts.Contact
                 |> Ash.Query.for_read(:get_by_user, %{user_id: user.id})
                 |> Ash.count(actor: user, authorize?: false) do
      {:ok, count} -> count
      {:error, _} -> 0
    end

    # Get paginated results
    contacts = case JumpstartAi.Accounts.Contact
                    |> Ash.Query.for_read(:get_by_user, %{user_id: user.id})
                    |> Ash.Query.select([
                      :id,
                      :firstname,
                      :lastname,
                      :email,
                      :company,
                      :phone,
                      :lifecycle_stage,
                      :source,
                      :external_updated_at,
                      :inserted_at
                    ])
                    |> Ash.Query.sort(inserted_at: :desc)
                    |> Ash.Query.offset(offset)
                    |> Ash.Query.limit(page_size)
                    |> Ash.read(actor: user, authorize?: false) do
      {:ok, contacts} -> contacts
      {:error, _} -> []
    end

    {contacts, total}
  end

  defp load_contact_notes_paginated(user, page, page_size) do
    offset = (page - 1) * page_size

    # Get total count
    total = case JumpstartAi.Accounts.ContactNote
                 |> Ash.Query.for_read(:read)
                 |> Ash.count(actor: user, authorize?: false) do
      {:ok, count} -> count
      {:error, _} -> 0
    end

    # Get paginated results
    notes = case JumpstartAi.Accounts.ContactNote
                 |> Ash.Query.for_read(:read)
                 |> Ash.Query.select([
                   :id,
                   :contact_id,
                   :content,
                   :note_type,
                   :source,
                   :external_created_at,
                   :inserted_at
                 ])
                 |> Ash.Query.sort(inserted_at: :desc)
                 |> Ash.Query.offset(offset)
                 |> Ash.Query.limit(page_size)
                 |> Ash.read(actor: user, authorize?: false) do
      {:ok, notes} -> notes
      {:error, _} -> []
    end

    {notes, total}
  end

  defp load_emails_paginated(user, page, page_size) do
    offset = (page - 1) * page_size

    # Get total count
    total = case JumpstartAi.Accounts.Email
                 |> Ash.Query.for_read(:read_user, %{user_id: user.id})
                 |> Ash.count(actor: user, authorize?: false) do
      {:ok, count} -> count
      {:error, _} -> 0
    end

    # Get paginated results
    emails = case JumpstartAi.Accounts.Email
                  |> Ash.Query.for_read(:read_user, %{user_id: user.id})
                  |> Ash.Query.select([
                    :id,
                    :subject,
                    :from_email,
                    :from_name,
                    :to_email,
                    :date,
                    :snippet,
                    :inserted_at
                  ])
                  |> Ash.Query.sort(date: :desc)
                  |> Ash.Query.offset(offset)
                  |> Ash.Query.limit(page_size)
                  |> Ash.read(actor: user, authorize?: false) do
      {:ok, emails} -> emails
      {:error, _} -> []
    end

    {emails, total}
  end

  defp load_tasks_paginated(user, page, page_size) do
    offset = (page - 1) * page_size

    # Get all user tasks for counting and pagination
    all_tasks = case JumpstartAi.Chat.Task
                     |> Ash.Query.for_read(:read)
                     |> Ash.read(actor: user, authorize?: false) do
      {:ok, tasks} -> Enum.filter(tasks, fn task -> task.user_id == user.id end)
      {:error, _} -> []
    end

    total = length(all_tasks)

    # Get paginated results
    tasks = all_tasks
            |> Enum.sort_by(&(&1.inserted_at), {:desc, DateTime})
            |> Enum.drop(offset)
            |> Enum.take(page_size)

    # Enhance tasks with tool call information from related messages
    tasks_with_tool_calls = Enum.map(tasks, fn task ->
      # Get recent messages from the task's conversation that contain tool calls
      tool_call_messages = case JumpstartAi.Chat.Message
                               |> Ash.Query.for_read(:read)
                               |> Ash.read(actor: user, authorize?: false) do
        {:ok, messages} ->
          messages
          |> Enum.filter(fn msg -> 
            msg.conversation_id == task.conversation_id && 
            msg.tool_calls && 
            length(msg.tool_calls) > 0 
          end)
          |> Enum.sort_by(&(&1.inserted_at), {:desc, DateTime})
          |> Enum.take(10)
        {:error, _} -> []
      end

      Map.put(task, :tool_call_messages, tool_call_messages)
    end)

    {tasks_with_tool_calls, total}
  end

  defp load_ongoing_instructions_paginated(user, page, page_size) do
    offset = (page - 1) * page_size

    # Get all user instructions for counting and pagination
    all_instructions = case JumpstartAi.Chat.OngoingInstruction
                           |> Ash.Query.for_read(:read)
                           |> Ash.read(actor: user, authorize?: false) do
      {:ok, instructions} -> Enum.filter(instructions, fn inst -> inst.user_id == user.id end)
      {:error, _} -> []
    end

    total = length(all_instructions)

    # Get paginated results
    instructions = all_instructions
                   |> Enum.sort_by(&(&1.inserted_at), {:desc, DateTime})
                   |> Enum.drop(offset)
                   |> Enum.take(page_size)

    {instructions, total}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-full bg-gray-50 flex flex-col">
      <!-- Header -->
      <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 bg-white">
        <h1 class="text-2xl font-semibold text-gray-900">Database Viewer</h1>
        <div class="flex items-center gap-3">
          <button
            phx-click="refresh_data"
            class="text-gray-400 hover:text-gray-600"
            aria-label="Refresh Data"
          >
            <%= if @loading do %>
              <svg class="animate-spin w-6 h-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
            <% else %>
              <.icon name="hero-arrow-path" class="w-6 h-6" />
            <% end %>
          </button>
          <.link navigate={~p"/settings"} class="text-gray-400 hover:text-gray-600" aria-label="Settings">
            <.icon name="hero-cog-6-tooth" class="w-6 h-6" />
          </.link>
          <.link navigate={~p"/chat"} class="text-gray-400 hover:text-gray-600" aria-label="Back to Chat">
            <.icon name="hero-arrow-left" class="w-6 h-6" />
          </.link>
          <.link navigate={~p"/"} class="text-gray-400 hover:text-gray-600" aria-label="Close">
            <.icon name="hero-x-mark" class="w-6 h-6" />
          </.link>
        </div>
      </div>

      <!-- Content Area -->
      <div class="flex-1 overflow-hidden flex flex-col">
        <div class="px-6 pt-8 pb-4">
          <div class="mb-6">
            <p class="text-sm text-gray-500">
              View your contacts, notes, emails, AI tasks, and ongoing instructions stored in the database
            </p>
          </div>

          <!-- Tab Navigation -->
          <div class="border-b border-gray-200">
            <nav class="-mb-px flex space-x-8">
                <button
                  phx-click="switch_tab"
                  phx-value-tab="contacts"
                  class={[
                    "py-2 px-1 border-b-2 font-medium text-sm",
                    if(@active_tab == :contacts,
                      do: "border-blue-500 text-blue-600",
                      else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                    )
                  ]}
                >
                  Contacts
                  <span class="ml-2 bg-gray-100 text-gray-900 py-0.5 px-2.5 rounded-full text-xs font-medium">
                    <%= @contacts_total %>
                  </span>
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="contact_notes"
                  class={[
                    "py-2 px-1 border-b-2 font-medium text-sm",
                    if(@active_tab == :contact_notes,
                      do: "border-blue-500 text-blue-600",
                      else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                    )
                  ]}
                >
                  Contact Notes
                  <span class="ml-2 bg-gray-100 text-gray-900 py-0.5 px-2.5 rounded-full text-xs font-medium">
                    <%= @contact_notes_total %>
                  </span>
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="emails"
                  class={[
                    "py-2 px-1 border-b-2 font-medium text-sm",
                    if(@active_tab == :emails,
                      do: "border-blue-500 text-blue-600",
                      else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                    )
                  ]}
                >
                  Emails
                  <span class="ml-2 bg-gray-100 text-gray-900 py-0.5 px-2.5 rounded-full text-xs font-medium">
                    <%= @emails_total %>
                  </span>
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="tasks"
                  class={[
                    "py-2 px-1 border-b-2 font-medium text-sm",
                    if(@active_tab == :tasks,
                      do: "border-blue-500 text-blue-600",
                      else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                    )
                  ]}
                >
                  Tasks
                  <span class="ml-2 bg-gray-100 text-gray-900 py-0.5 px-2.5 rounded-full text-xs font-medium">
                    <%= @tasks_total %>
                  </span>
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="ongoing_instructions"
                  class={[
                    "py-2 px-1 border-b-2 font-medium text-sm",
                    if(@active_tab == :ongoing_instructions,
                      do: "border-blue-500 text-blue-600",
                      else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                    )
                  ]}
                >
                  Instructions
                  <span class="ml-2 bg-gray-100 text-gray-900 py-0.5 px-2.5 rounded-full text-xs font-medium">
                    <%= @ongoing_instructions_total %>
                  </span>
                </button>
              </nav>
          </div>
        </div>

        <!-- Table Content Area -->
        <div class="flex-1 overflow-y-auto bg-gray-50">
          <div class="p-6">
            <div class="bg-white shadow sm:rounded-lg">
              <%= if @loading do %>
                <div class="p-8 text-center">
                  <svg class="animate-spin mx-auto h-8 w-8 text-gray-400" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                  <p class="mt-2 text-gray-500">Loading data...</p>
                </div>
              <% else %>
                <%= case @active_tab do %>
                  <% :contacts -> %>
                    <.contacts_table contacts={@contacts} />
                    <.pagination_controls
                      table="contacts"
                      current_page={@contacts_page}
                      total_records={@contacts_total}
                      page_size={@page_size}
                    />
                  <% :contact_notes -> %>
                    <.contact_notes_table contact_notes={@contact_notes} />
                    <.pagination_controls
                      table="contact_notes"
                      current_page={@contact_notes_page}
                      total_records={@contact_notes_total}
                      page_size={@page_size}
                    />
                  <% :emails -> %>
                    <.emails_table emails={@emails} />
                    <.pagination_controls
                      table="emails"
                      current_page={@emails_page}
                      total_records={@emails_total}
                      page_size={@page_size}
                    />
                  <% :tasks -> %>
                    <.tasks_table tasks={@tasks} />
                    <.pagination_controls
                      table="tasks"
                      current_page={@tasks_page}
                      total_records={@tasks_total}
                      page_size={@page_size}
                    />
                  <% :ongoing_instructions -> %>
                    <.ongoing_instructions_table ongoing_instructions={@ongoing_instructions} />
                    <.pagination_controls
                      table="ongoing_instructions"
                      current_page={@ongoing_instructions_page}
                      total_records={@ongoing_instructions_total}
                      page_size={@page_size}
                    />
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def contacts_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@contacts) do %>
        <div class="p-8 text-center">
          <p class="text-gray-500">No contacts found</p>
        </div>
      <% else %>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Email</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Company</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Phone</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Source</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Stage</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Added</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for contact <- @contacts do %>
              <tr class="hover:bg-gray-50">
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                  <%= "#{contact.firstname || ""} #{contact.lastname || ""}" |> String.trim() %>
                  <%= if String.trim("#{contact.firstname || ""} #{contact.lastname || ""}") == "" do %>
                    <span class="text-gray-400">No name</span>
                  <% end %>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= contact.email || "-" %></td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= contact.company || "-" %></td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= contact.phone || "-" %></td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                    case contact.source do
                      "hubspot" -> "bg-orange-100 text-orange-800"
                      "google" -> "bg-blue-100 text-blue-800"
                      _ -> "bg-gray-100 text-gray-800"
                    end
                  ]}>
                    <%= contact.source %>
                  </span>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= contact.lifecycle_stage || "-" %></td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if contact.inserted_at do %>
                    <%= Calendar.strftime(contact.inserted_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    -
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  def contact_notes_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@contact_notes) do %>
        <div class="p-8 text-center">
          <p class="text-gray-500">No contact notes found</p>
        </div>
      <% else %>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Contact ID</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Type</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Source</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Content Preview</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Added</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for note <- @contact_notes do %>
              <tr class="hover:bg-gray-50">
                <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-600">
                  <%= String.slice(to_string(note.contact_id), 0, 8) %>...
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= note.note_type || "NOTE" %></td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                    case note.source do
                      "hubspot" -> "bg-orange-100 text-orange-800"
                      "google" -> "bg-blue-100 text-blue-800"
                      _ -> "bg-gray-100 text-gray-800"
                    end
                  ]}>
                    <%= note.source %>
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900">
                  <div class="max-w-lg truncate">
                    <%= if note.content && String.trim(note.content) != "" do %>
                      <%= String.slice(note.content, 0, 150) %><%= if String.length(note.content) > 150, do: "...", else: "" %>
                    <% else %>
                      <span class="text-gray-400">No content</span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if note.inserted_at do %>
                    <%= Calendar.strftime(note.inserted_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    -
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  def emails_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@emails) do %>
        <div class="p-8 text-center">
          <p class="text-gray-500">No emails found</p>
        </div>
      <% else %>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Subject</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">From</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">To</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Snippet</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Added</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for email <- @emails do %>
              <tr class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">
                  <div class="max-w-sm truncate">
                    <%= email.subject || "No Subject" %>
                  </div>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900">
                  <%= if email.from_name && String.trim(email.from_name) != "" do %>
                    <%= email.from_name %>
                    <br>
                    <span class="text-xs text-gray-500"><%= email.from_email %></span>
                  <% else %>
                    <%= email.from_email || "-" %>
                  <% end %>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900"><%= email.to_email || "-" %></td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  <div class="max-w-lg truncate">
                    <%= email.snippet || "No preview available" %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if email.inserted_at do %>
                    <%= Calendar.strftime(email.inserted_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    -
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  def pagination_controls(assigns) do
    total_pages = ceil(assigns.total_records / assigns.page_size)

    assigns = assign(assigns, :total_pages, total_pages)

    ~H"""
    <div class="bg-white px-4 py-3 border-t border-gray-200 sm:px-6">
      <div class="flex items-center justify-between">
        <div class="flex-1 flex justify-between sm:hidden">
          <!-- Mobile pagination -->
          <%= if @current_page > 1 do %>
            <button
              phx-click="paginate"
              phx-value-table={@table}
              phx-value-page={@current_page - 1}
              class="relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Previous
            </button>
          <% else %>
            <span class="relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-400 bg-gray-100 cursor-not-allowed">
              Previous
            </span>
          <% end %>

          <%= if @current_page < @total_pages do %>
            <button
              phx-click="paginate"
              phx-value-table={@table}
              phx-value-page={@current_page + 1}
              class="ml-3 relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Next
            </button>
          <% else %>
            <span class="ml-3 relative inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-400 bg-gray-100 cursor-not-allowed">
              Next
            </span>
          <% end %>
        </div>

        <div class="hidden sm:flex-1 sm:flex sm:items-center sm:justify-between">
          <div>
            <p class="text-sm text-gray-700">
              Showing
              <span class="font-medium"><%= (@current_page - 1) * @page_size + 1 %></span>
              to
              <span class="font-medium"><%= min(@current_page * @page_size, @total_records) %></span>
              of
              <span class="font-medium"><%= @total_records %></span>
              results
            </p>
          </div>

          <div>
            <nav class="relative z-0 inline-flex rounded-md shadow-sm -space-x-px" aria-label="Pagination">
              <!-- Previous button -->
              <%= if @current_page > 1 do %>
                <button
                  phx-click="paginate"
                  phx-value-table={@table}
                  phx-value-page={@current_page - 1}
                  class="relative inline-flex items-center px-2 py-2 rounded-l-md border border-gray-300 bg-white text-sm font-medium text-gray-500 hover:bg-gray-50"
                >
                  <span class="sr-only">Previous</span>
                  <svg class="h-5 w-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M12.707 5.293a1 1 0 010 1.414L9.414 10l3.293 3.293a1 1 0 01-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z" clip-rule="evenodd" />
                  </svg>
                </button>
              <% else %>
                <span class="relative inline-flex items-center px-2 py-2 rounded-l-md border border-gray-300 bg-gray-100 text-sm font-medium text-gray-400 cursor-not-allowed">
                  <span class="sr-only">Previous</span>
                  <svg class="h-5 w-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M12.707 5.293a1 1 0 010 1.414L9.414 10l3.293 3.293a1 1 0 01-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z" clip-rule="evenodd" />
                  </svg>
                </span>
              <% end %>

              <!-- Page numbers -->
              <%= for page <- pagination_range(@current_page, @total_pages) do %>
                <%= cond do %>
                  <% page == @current_page -> %>
                    <span class="z-10 bg-blue-50 border-blue-500 text-blue-600 relative inline-flex items-center px-4 py-2 border text-sm font-medium">
                      <%= page %>
                    </span>
                  <% page == :ellipsis -> %>
                    <span class="relative inline-flex items-center px-4 py-2 border border-gray-300 bg-white text-sm font-medium text-gray-700">
                      ...
                    </span>
                  <% true -> %>
                    <button
                      phx-click="paginate"
                      phx-value-table={@table}
                      phx-value-page={page}
                      class="bg-white border-gray-300 text-gray-500 hover:bg-gray-50 relative inline-flex items-center px-4 py-2 border text-sm font-medium"
                    >
                      <%= page %>
                    </button>
                <% end %>
              <% end %>

              <!-- Next button -->
              <%= if @current_page < @total_pages do %>
                <button
                  phx-click="paginate"
                  phx-value-table={@table}
                  phx-value-page={@current_page + 1}
                  class="relative inline-flex items-center px-2 py-2 rounded-r-md border border-gray-300 bg-white text-sm font-medium text-gray-500 hover:bg-gray-50"
                >
                  <span class="sr-only">Next</span>
                  <svg class="h-5 w-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                  </svg>
                </button>
              <% else %>
                <span class="relative inline-flex items-center px-2 py-2 rounded-r-md border border-gray-300 bg-gray-100 text-sm font-medium text-gray-400 cursor-not-allowed">
                  <span class="sr-only">Next</span>
                  <svg class="h-5 w-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                  </svg>
                </span>
              <% end %>
            </nav>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def tasks_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@tasks) do %>
        <div class="p-8 text-center">
          <p class="text-gray-500">No tasks found</p>
        </div>
      <% else %>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Description</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Status</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Tool Calls</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Context</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Next Action</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Created</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for task <- @tasks do %>
              <tr class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">
                  <div class="max-w-sm truncate">
                    <%= task.description %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                    case task.status do
                      :active -> "bg-blue-100 text-blue-800"
                      :waiting_for_response -> "bg-yellow-100 text-yellow-800"
                      :completed -> "bg-green-100 text-green-800"
                      :failed -> "bg-red-100 text-red-800"
                      _ -> "bg-gray-100 text-gray-800"
                    end
                  ]}>
                    <%= String.upcase(to_string(task.status)) %>
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  <div class="max-w-xs">
                    <%= if Map.has_key?(task, :tool_call_messages) && !Enum.empty?(task.tool_call_messages) do %>
                      <details class="cursor-pointer">
                        <summary class="text-blue-600 hover:text-blue-800">
                          <%= Enum.count(task.tool_call_messages) %> messages with tool calls
                        </summary>
                        <div class="mt-2 space-y-2 max-h-40 overflow-auto">
                          <%= for message <- Enum.take(task.tool_call_messages, 3) do %>
                            <div class="text-xs bg-gray-50 p-2 rounded">
                              <div class="font-medium text-gray-700 mb-1">
                                <%= Calendar.strftime(message.inserted_at, "%Y-%m-%d %H:%M") %>
                              </div>
                              <%= for tool_call <- message.tool_calls || [] do %>
                                <div class="flex items-center gap-2 mb-1">
                                  <span class={[
                                    "inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium",
                                    case Map.get(tool_call, "status") do
                                      "complete" -> "bg-green-100 text-green-800"
                                      "pending" -> "bg-yellow-100 text-yellow-800"
                                      _ -> "bg-gray-100 text-gray-800"
                                    end
                                  ]}>
                                    <%= Map.get(tool_call, "status", "unknown") %>
                                  </span>
                                  <span class="font-mono text-blue-800">
                                    <%= Map.get(tool_call, "name", "unknown") %>
                                  </span>
                                </div>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      </details>
                    <% else %>
                      <span class="text-gray-400">No tool calls</span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  <div class="max-w-xs truncate">
                    <%= if task.context && map_size(task.context) > 0 do %>
                      <details class="cursor-pointer">
                        <summary class="text-blue-600 hover:text-blue-800">Show context</summary>
                        <pre class="mt-2 text-xs bg-gray-100 p-2 rounded overflow-auto max-h-32"><%= Jason.encode!(task.context, pretty: true) %></pre>
                      </details>
                    <% else %>
                      <span class="text-gray-400">No context</span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900">
                  <div class="max-w-xs truncate">
                    <%= task.next_action || "-" %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if task.inserted_at do %>
                    <%= Calendar.strftime(task.inserted_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    -
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  def ongoing_instructions_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <%= if Enum.empty?(@ongoing_instructions) do %>
        <div class="p-8 text-center">
          <p class="text-gray-500">No ongoing instructions found</p>
        </div>
      <% else %>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Instruction</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Active</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Trigger Conditions</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Last Triggered</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Created</th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for instruction <- @ongoing_instructions do %>
              <tr class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">
                  <div class="max-w-md truncate">
                    <%= instruction.instruction %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap">
                  <span class={[
                    "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                    if(instruction.is_active,
                      do: "bg-green-100 text-green-800",
                      else: "bg-gray-100 text-gray-800"
                    )
                  ]}>
                    <%= if instruction.is_active, do: "ACTIVE", else: "INACTIVE" %>
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  <div class="max-w-xs truncate">
                    <%= if instruction.trigger_conditions && map_size(instruction.trigger_conditions) > 0 do %>
                      <details class="cursor-pointer">
                        <summary class="text-blue-600 hover:text-blue-800">Show conditions</summary>
                        <pre class="mt-2 text-xs bg-gray-100 p-2 rounded overflow-auto max-h-32"><%= Jason.encode!(instruction.trigger_conditions, pretty: true) %></pre>
                      </details>
                    <% else %>
                      <span class="text-gray-400">No conditions</span>
                    <% end %>
                  </div>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if instruction.last_triggered_at do %>
                    <%= Calendar.strftime(instruction.last_triggered_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    <span class="text-gray-400">Never</span>
                  <% end %>
                </td>
                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  <%= if instruction.inserted_at do %>
                    <%= Calendar.strftime(instruction.inserted_at, "%Y-%m-%d %H:%M") %>
                  <% else %>
                    -
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  # Helper function to generate pagination range with ellipsis
  defp pagination_range(_current_page, total_pages) when total_pages <= 7 do
    Enum.to_list(1..total_pages)
  end

  defp pagination_range(current_page, total_pages) do
    cond do
      current_page <= 4 ->
        [1, 2, 3, 4, 5, :ellipsis, total_pages]

      current_page >= total_pages - 3 ->
        [1, :ellipsis, total_pages - 4, total_pages - 3, total_pages - 2, total_pages - 1, total_pages]

      true ->
        [1, :ellipsis, current_page - 1, current_page, current_page + 1, :ellipsis, total_pages]
    end
  end
end
