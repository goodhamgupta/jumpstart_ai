defmodule JumpstartAi.Workers.ProactiveAgent do
  use Oban.Worker, queue: :proactive_actions

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "event_type" => event_type, "event_data" => event_data}
      }) do
    Logger.info("ProactiveAgent: Processing individual event #{event_type} for user #{user_id}")

    # Get user's ongoing instructions
    case JumpstartAi.Chat.OngoingInstruction
         |> Ash.Query.for_read(:active_for_user, %{user_id: user_id})
         |> Ash.read() do
      {:ok, instructions} ->
        # Check each instruction against the event
        Enum.each(instructions, fn instruction ->
          if should_trigger?(instruction, event_type, event_data) do
            execute_proactive_action(instruction, event_type, event_data)
          end
        end)

        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to fetch ongoing instructions for user #{user_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp should_trigger?(instruction, event_type, event_data) do
    # Check if this individual event matches the instruction's trigger conditions
    case {instruction.trigger_conditions, event_type} do
      {%{"trigger" => "new_email_from_unknown_sender"}, "new_email"} ->
        is_unknown_sender?(event_data)

      {%{"trigger" => "new_contact_created"}, "new_contact"} ->
        true

      {%{"trigger" => "new_calendar_event"}, "new_calendar_event"} ->
        true

      {%{"trigger" => "email_from_sender", "sender_email" => sender_email}, "new_email"} ->
        event_data["sender_email"] == sender_email

      _ ->
        false
    end
  end

  defp is_unknown_sender?(email_data) do
    sender_email = Map.get(email_data, "sender_email")
    sender_email && !sender_known?(sender_email)
  end

  defp sender_known?(sender_email) do
    # Check if sender exists in contacts
    try do
      case JumpstartAi.Accounts.Contact
           |> Ash.Query.for_read(:read)
           |> Ash.Query.select([:email])
           |> Ash.Query.limit(100)
           |> Ash.read!(authorize?: false) do
        contacts ->
          Enum.any?(contacts, fn contact -> contact.email == sender_email end)
      end
    rescue
      # If Contact resource doesn't exist or query fails, assume unknown
      _ -> false
    end
  end

  defp execute_proactive_action(instruction, event_type, event_data) do
    Logger.info(
      "Starting execution of proactive action for instruction #{instruction.id}, event: #{event_type}"
    )

    # Get user and create a proactive conversation
    case JumpstartAi.Accounts.User |> Ash.get(instruction.user_id, authorize?: false) do
      {:ok, user} ->
        Logger.debug("Fetched user successfully: #{user.id}")

        # Create a new conversation for the proactive action
        case JumpstartAi.Chat.create_conversation(%{}, actor: user) do
          {:ok, conversation} ->
            Logger.debug("Created proactive conversation: #{conversation.id}")

            # Build proactive prompt as a USER message (not system)
            prompt = build_proactive_prompt(instruction, event_type, event_data)
            Logger.debug("Built proactive prompt: #{String.slice(prompt, 0, 200)}...")

            case JumpstartAi.Chat.create_message(
                   %{text: prompt},
                   actor: user,
                   private_arguments: %{conversation_id: conversation.id}
                 ) do
              {:ok, _message} ->
                Logger.info(
                  "Proactive message created successfully - LLM will respond via Oban worker"
                )

                # Update instruction last triggered time
                instruction
                |> Ash.Changeset.for_update(:mark_triggered)
                |> Ash.update()

                Logger.info("Proactive action queued for instruction #{instruction.id}")
                :ok

              {:error, reason} ->
                Logger.error("Failed to create proactive message: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error("Failed to create proactive conversation: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to fetch user #{instruction.user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_proactive_prompt(instruction, event_type, event_data) do
    Logger.debug(
      "Building proactive prompt for instruction #{instruction.id}, event: #{event_type}"
    )

    """
    PROACTIVE ACTION REQUESTED

    You are executing a standing instruction that was triggered automatically based on a new event.

    ONGOING INSTRUCTION:
    #{instruction.instruction}

    EVENT DETAILS:
    #{format_event_with_intelligence(event_type, event_data)}

    YOUR TASK:
    Execute the ongoing instruction using your available tools. Be thorough and professional.

    IMPORTANT GUIDELINES:
    - For emails from unknown senders: Extract the sender's email address from the event above, then use create_hubspot_contact with that email to add them to HubSpot CRM
    - For emails: ALWAYS draft first using draft_email, then send using send_email_with_draft if appropriate
    - For HubSpot contacts: Use create_hubspot_contact with the email address (required), firstname, lastname, company, and phone (all optional)
    - For contact notes: Add contextual notes with create_contact_note after creating or finding contacts
    - For calendar: Check for conflicts using semantic_search_calendar_events, notify attendees via email
    - Search for existing data before creating duplicates (use search_contacts, semantic_search_emails, etc.)
    - Be proactive but thoughtful - if you're uncertain about a step, explain your reasoning

    EXAMPLE for unknown email senders:
    If you see "From: John Doe <john@example.com>", extract the email "john@example.com" and create a contact:
    create_hubspot_contact(email: "john@example.com", firstname: "John", lastname: "Doe")

    Execute this instruction now using the tools at your disposal.
    """
  end

  defp format_event_with_intelligence("new_email", email) do
    sender_display =
      if email["sender_name"],
        do: "#{email["sender_name"]} <#{email["sender_email"]}>",
        else: email["sender_email"]

    """
    New Email Received:
    - From: #{sender_display}
    - Subject: #{email["subject"]}
    - Date: #{email["date"] || "N/A"}
    - Snippet: #{email["snippet"] || "N/A"}
    """
  end

  defp format_event_with_intelligence("new_contact", contact) do
    """
    New Contact Created:
    - Name: #{contact["name"]}
    - Email: #{contact["email"]}
    """
  end

  defp format_event_with_intelligence("new_calendar_event", event) do
    attendees_info =
      if event["attendees"] && length(event["attendees"]) > 0,
        do: "#{length(event["attendees"])} attendees",
        else: "No attendees"

    """
    New Calendar Event Created:
    - Summary: #{event["summary"]}
    - Start Time: #{event["start_time"]}
    - Attendees: #{attendees_info}
    """
  end

  defp format_event_with_intelligence(event_type, event_data) do
    """
    Event Type: #{event_type}
    Event Data: #{inspect(event_data)}
    """
  end
end
