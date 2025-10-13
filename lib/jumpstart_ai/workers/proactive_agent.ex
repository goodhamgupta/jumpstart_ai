defmodule JumpstartAi.Workers.ProactiveAgent do
  use Oban.Worker, queue: :proactive_actions

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "changes" => changes}}) do
    # Get user's ongoing instructions
    case JumpstartAi.Chat.OngoingInstruction
         |> Ash.Query.for_read(:active_for_user, %{user_id: user_id})
         |> Ash.read() do
      {:ok, instructions} ->
        # Check each instruction against the changes
        Enum.each(instructions, fn instruction ->
          if should_trigger?(instruction, changes) do
            execute_proactive_action(instruction, changes)
          end
        end)

        :ok

      {:error, reason} ->
        Logger.error("Failed to fetch ongoing instructions for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp should_trigger?(instruction, changes) do
    # Simple logic - if changes match instruction conditions
    case instruction.trigger_conditions do
      %{"trigger" => "new_email_from_unknown_sender"} ->
        has_new_unknown_emails?(changes)

      %{"trigger" => "new_contact_created"} ->
        has_new_contacts?(changes)

      %{"trigger" => "new_calendar_event"} ->
        has_new_calendar_events?(changes)

      %{"trigger" => "email_from_sender", "sender_email" => sender_email} ->
        has_email_from_sender?(changes, sender_email)

      _ ->
        false
    end
  end

  defp has_new_unknown_emails?(changes) do
    new_emails = Map.get(changes, "new_emails", [])

    Enum.any?(new_emails, fn email ->
      # Check if sender is not in contacts or HubSpot
      sender_email = Map.get(email, "sender_email")
      sender_email && !sender_known?(sender_email)
    end)
  end

  defp has_new_contacts?(changes) do
    new_contacts = Map.get(changes, "new_contacts", [])
    length(new_contacts) > 0
  end

  defp has_new_calendar_events?(changes) do
    new_events = Map.get(changes, "new_calendar_events", [])
    length(new_events) > 0
  end

  defp has_email_from_sender?(changes, sender_email) do
    new_emails = Map.get(changes, "new_emails", [])

    Enum.any?(new_emails, fn email ->
      Map.get(email, "sender_email") == sender_email
    end)
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

  defp execute_proactive_action(instruction, changes) do
    # Get user and create a proactive conversation
    case JumpstartAi.Accounts.User |> Ash.get(instruction.user_id) do
      {:ok, user} ->
        # Create a new conversation for the proactive action
        case JumpstartAi.Chat.create_conversation(%{actor: user}) do
          {:ok, conversation} ->
            # Create the proactive message
            prompt = build_proactive_prompt(instruction, changes)

            case JumpstartAi.Chat.create_message(%{
                   content: prompt,
                   source: :system,
                   conversation_id: conversation.id,
                   actor: user
                 }) do
              {:ok, _message} ->
                # Update instruction last triggered time
                JumpstartAi.Chat.OngoingInstruction
                |> Ash.Changeset.for_update(:mark_triggered, instruction)
                |> Ash.update()

                Logger.info("Proactive action executed for instruction #{instruction.id}")

              {:error, reason} ->
                Logger.error("Failed to create proactive message: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.error("Failed to create proactive conversation: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to fetch user #{instruction.user_id}: #{inspect(reason)}")
    end
  end

  defp build_proactive_prompt(instruction, changes) do
    """
    PROACTIVE ACTION NEEDED:
    
    Your ongoing instruction: #{instruction.instruction}
    
    Recent changes that triggered this:
    #{format_changes(changes)}
    
    Please take the appropriate action using your available tools.
    Remember to draft emails before sending and be helpful to the user.
    """
  end

  defp format_changes(changes) do
    changes
    |> Enum.map(fn {key, value} ->
      "- #{key}: #{inspect(value)}"
    end)
    |> Enum.join("\n")
  end
end