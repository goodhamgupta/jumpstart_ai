defmodule JumpstartAi.Chat.Message.Changes.Respond do
  use Ash.Resource.Change
  require Ash.Query
  import Ash.Expr

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI

  defp to_text(nil), do: ""
  defp to_text(s) when is_binary(s), do: s
  defp to_text(%LangChain.Message.ContentPart{type: :text, content: c}) when is_binary(c), do: c
  defp to_text(%LangChain.Message.ContentPart{}), do: ""

  defp to_text(parts) when is_list(parts) do
    parts
    |> Enum.map(&to_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp to_text(_), do: ""

  defp extract_thinking_content(nil), do: ""

  # Handle Anthropic thinking content
  defp extract_thinking_content(%LangChain.Message.ContentPart{type: :thinking, content: c})
       when is_binary(c),
       do: c

  # Handle OpenAI reasoning summary (stored as :unsupported with type: "reasoning")
  defp extract_thinking_content(%LangChain.Message.ContentPart{
         type: :unsupported,
         options: options
       }) do
    case options do
      %{type: "reasoning", summary: summary} when is_binary(summary) -> summary
      _ -> ""
    end
  end

  defp extract_thinking_content(%LangChain.Message.ContentPart{}), do: ""

  defp extract_thinking_content(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn part ->
      match?(%LangChain.Message.ContentPart{type: :thinking}, part) ||
        match?(
          %LangChain.Message.ContentPart{type: :unsupported, options: %{type: "reasoning"}},
          part
        )
    end)
    |> Enum.map(fn part ->
      case part do
        %{type: :thinking, content: c} -> c
        %{type: :unsupported, options: %{summary: s}} -> s
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_thinking_content(_), do: ""

  @impl true
  def change(changeset, _opts, context) do
    require Logger

    Ash.Changeset.before_transaction(changeset, fn changeset ->
      message = changeset.data

      # Load the user from the conversation to use as actor
      actor =
        case context.actor do
          nil ->
            Logger.warning(
              "Respond: context.actor is nil for message #{message.id}, fetching from conversation"
            )

            # Load conversation with user relationship
            case JumpstartAi.Chat.Conversation
                 |> Ash.Query.load(:user)
                 |> Ash.get(message.conversation_id, authorize?: false) do
              {:ok, %{user: user}} when not is_nil(user) ->
                Logger.info(
                  "Respond: Loaded user #{user.id} from conversation #{message.conversation_id}"
                )

                # Set metadata to mark as chat agent, same as AiAgentActorPersister
                Ash.Resource.set_metadata(user, %{chat_agent?: true})

              {:ok, conversation} ->
                Logger.error(
                  "Respond: Conversation #{message.conversation_id} loaded but user is nil or not loaded"
                )

                Logger.info(
                  "Respond: Attempting direct user fetch with user_id: #{conversation.user_id}"
                )

                case JumpstartAi.Accounts.User
                     |> Ash.get(conversation.user_id, authorize?: false) do
                  {:ok, user} ->
                    Logger.info("Respond: Successfully loaded user #{user.id} directly")
                    # Set metadata to mark as chat agent
                    Ash.Resource.set_metadata(user, %{chat_agent?: true})

                  error ->
                    Logger.error("Respond: Failed to load user directly: #{inspect(error)}")
                    nil
                end

              error ->
                Logger.error(
                  "Respond: Failed to load conversation #{message.conversation_id}: #{inspect(error)}"
                )

                nil
            end

          %JumpstartAi.Accounts.User{} = actor ->
            Logger.info("Respond: Using actor from context: #{actor.id}")
            # Always set metadata to mark as chat agent, even when actor is already present
            Ash.Resource.set_metadata(actor, %{chat_agent?: true})

          actor when not is_nil(actor) ->
            # Actor is not nil but also not a User struct - need to reload
            Logger.warning(
              "Respond: Actor from context is not a User struct (#{inspect(actor)}), reloading from conversation"
            )

            case JumpstartAi.Chat.Conversation
                 |> Ash.Query.load(:user)
                 |> Ash.get(message.conversation_id, authorize?: false) do
              {:ok, %{user: user}} when not is_nil(user) ->
                Logger.info("Respond: Reloaded user #{user.id} from conversation")
                Ash.Resource.set_metadata(user, %{chat_agent?: true})

              {:ok, conversation} ->
                case JumpstartAi.Accounts.User
                     |> Ash.get(conversation.user_id, authorize?: false) do
                  {:ok, user} ->
                    Logger.info("Respond: Reloaded user #{user.id} directly")
                    Ash.Resource.set_metadata(user, %{chat_agent?: true})

                  error ->
                    Logger.error("Respond: Failed to reload user: #{inspect(error)}")
                    nil
                end

              error ->
                Logger.error("Respond: Failed to reload conversation: #{inspect(error)}")
                nil
            end

          _ ->
            Logger.error("Respond: Unexpected actor value in context")
            nil
        end

      unless actor do
        raise "Cannot proceed with respond: actor is nil for message #{message.id}"
      end

      messages =
        JumpstartAi.Chat.Message
        |> Ash.Query.do_filter(expr(conversation_id == ^message.conversation_id))
        |> Ash.Query.do_filter(expr(id != ^message.id))
        |> Ash.Query.select([:text, :source, :tool_calls, :tool_results, :reasoning_content])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read!()
        |> Enum.concat([%{source: :user, text: message.text}])

      system_prompt =
        LangChain.Message.new_system!("""
        You are an JumpstartAI, an AI assistant for financial advisors with persistent memory and proactive capabilities.
        Your job is to use the tools at your disposal to assist the user with managing emails, contacts, calendar events, and notes.

        CURRENT CONTEXT:
        - Current conversation_id: #{message.conversation_id}
        - Current timezone is UTC.
        - Current date is #{DateTime.utc_now() |> DateTime.to_date()}
        - Current time is #{DateTime.utc_now() |> DateTime.to_time()}

        TASK MANAGEMENT:
        - For complex multi-step requests, create a task to track progress using create_task
        - IMPORTANT: Always use the current conversation_id (#{message.conversation_id}) when creating tasks
        - Update task status as you complete steps using update_task_status
        - When waiting for external responses (emails), mark task as "waiting_for_response"
        - Use list_active_tasks to see what tasks are currently in progress

        ONGOING INSTRUCTIONS:
        - When users give standing instructions like "When X happens, do Y", create an ongoing instruction using create_ongoing_instruction
        - These will trigger automatically when conditions are met during periodic syncs
        - Use list_ongoing_instructions to see what proactive rules are in place

        IMPORTANT EMAIL SAFETY RULES:
        - ALWAYS use draft_email first when composing any email
        - When user says "send" or explicitly requests sending, immediately send the draft using send_email_with_draft
        - When drafting without explicit send instruction, show draft details and ask for confirmation
        - EXCEPTION: When scheduling appointments/calendar events, automatically send the notification email after drafting (don't wait for confirmation)
        - Example workflows:
          * User: "Draft an email to John about the meeting" -> Draft and ask for confirmation
          * User: "Send an email to John about the meeting" -> Draft and immediately send
          * User: "Schedule appointment with Sara Smith" -> Create event, draft notification email, and immediately send
          * User: "Send" (referring to existing draft) -> Immediately send the draft
        - Use list_drafts to help users review and manage their pending emails
        - Use send_email_with_draft (with draft_id) as the ONLY way to send emails

        IMPORTANT CONTACT MENTION HANDLING:
        - When users mention contacts using @[Name](contact_id) format, parse the contact_id from the mention
        - ALWAYS use get_contact_by_id with the exact contact_id from the mention
        - Do NOT search by name when a contact_id is provided in a mention
        - Example: "tell me about @[John Doe](abc-123-def)" -> use get_contact_by_id with contact_id "abc-123-def"
        - The contact_id in mentions is the definitive reference - use it directly
        - Only fall back to search_contacts when no contact_id is provided or when the user asks for a general search

        EXAMPLES:
        User: "Schedule appointment with Sara Smith"
        You: Create task, find Sara in contacts/HubSpot, create calendar event, draft notification email, send the email immediately, mark task as complete

        User: "When unknown senders email me, create HubSpot contact"
        You: Create ongoing instruction with trigger conditions

        Available capabilities:
        - Search and analyze emails, contacts, notes, and calendar events semantically
        - List recent emails, contacts, notes, and calendar events for quick overview
        - Get detailed contact information by ID when mentioned in messages
        - Create email drafts for user review and send approved drafts
        - Create calendar events and schedule meetings with attendees
        - Create and manage tasks for complex multi-step processes
        - Create ongoing instructions for proactive behavior
        - Find relevant information using AI-powered search

        Always draft emails before sending. Be proactive when ongoing instructions match events.
        """)

      message_chain = message_chain(messages)

      new_message_id = Ash.UUID.generate()

      %{
        llm:
          ChatOpenAI.new!(%{
            model: "gpt-5-mini-2025-08-07",
            stream: true,
            reasoning_mode: true,
            reasoning_effort: "medium",
            custom_context: Map.new(Ash.Context.to_opts(context))
          })
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(system_prompt)
      |> LLMChain.add_messages(message_chain)
      |> AshAi.setup_ash_ai(
        otp_app: :jumpstart_ai,
        tools: [
          :search_emails_by_from,
          :semantic_search_emails,
          :semantic_search_contacts,
          :semantic_search_contact_notes,
          :semantic_search_calendar_events,
          :draft_email,
          :list_drafts,
          :send_email_with_draft,
          :create_calendar_event,
          :list_emails,
          :list_contacts,
          :list_contact_notes,
          :list_calendar_events,
          :search_contacts,
          :get_contact_by_id,
          :create_hubspot_contact,
          :create_contact_note,
          :create_task,
          :update_task_status,
          :list_active_tasks,
          :create_ongoing_instruction,
          :list_ongoing_instructions
        ],
        actor: actor
      )
      |> LLMChain.add_callback(%{
        on_llm_new_delta: fn _chain, deltas ->
          content =
            deltas
            |> Enum.map(& &1.content)
            |> Enum.reject(&is_nil/1)
            |> Enum.join("")

          # Extract thinking/reasoning content from deltas
          thinking_content =
            deltas
            |> Enum.flat_map(fn delta ->
              case delta.merged_content do
                parts when is_list(parts) -> parts
                part when not is_nil(part) -> [part]
                _ -> []
              end
            end)
            |> Enum.filter(fn part ->
              match?(%LangChain.Message.ContentPart{type: :thinking}, part) ||
                match?(
                  %LangChain.Message.ContentPart{
                    type: :unsupported,
                    options: %{type: "reasoning"}
                  },
                  part
                )
            end)
            |> Enum.map(fn part ->
              case part do
                %{type: :thinking, content: c} -> c
                %{type: :unsupported, options: %{summary: s}} -> s
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.join("")

          if content != "" || thinking_content != "" do
            params = %{
              id: new_message_id,
              response_to_id: message.id,
              conversation_id: message.conversation_id
            }

            params =
              if content != "", do: Map.put(params, :text, content), else: params

            params =
              if thinking_content != "",
                do: Map.put(params, :reasoning_content, thinking_content),
                else: params

            JumpstartAi.Chat.Message
            |> Ash.Changeset.for_create(
              :upsert_response,
              params,
              actor: %AshAi{}
            )
            |> Ash.create!()
          end
        end,
        on_message_processed: fn _chain, data ->
          text = to_text(data.content)
          thinking = extract_thinking_content(data.content)

          if (data.tool_calls && Enum.any?(data.tool_calls)) ||
               (data.tool_results && Enum.any?(data.tool_results)) ||
               text != "" ||
               thinking != "" do
            params = %{
              id: new_message_id,
              response_to_id: message.id,
              conversation_id: message.conversation_id,
              complete: true,
              tool_calls:
                data.tool_calls &&
                  Enum.map(
                    data.tool_calls,
                    &Map.take(&1, [:status, :type, :call_id, :name, :arguments, :index])
                  ),
              tool_results:
                data.tool_results &&
                  Enum.map(
                    data.tool_results,
                    fn tool_result ->
                      tool_result
                      |> Map.take([
                        :type,
                        :tool_call_id,
                        :name,
                        :content,
                        :display_text,
                        :is_error,
                        :options
                      ])
                      |> Map.update(:content, nil, &to_text/1)
                    end
                  ),
              text: text
            }

            params =
              if thinking != "",
                do: Map.put(params, :reasoning_content, thinking),
                else: params

            JumpstartAi.Chat.Message
            |> Ash.Changeset.for_create(
              :upsert_response,
              params,
              actor: %AshAi{}
            )
            |> Ash.create!()
          end
        end
      })
      |> LLMChain.run(mode: :while_needs_response)

      changeset
    end)
  end

  defp message_chain(messages) do
    Enum.flat_map(messages, fn
      %{source: :agent} = message ->
        # Build the message params, conditionally including content
        # OpenAI API requires content to be a non-null string or omitted when there are tool calls
        message_params = %{}

        message_params =
          if message.tool_calls && !Enum.empty?(message.tool_calls) do
            Map.put(
              message_params,
              :tool_calls,
              Enum.map(
                message.tool_calls,
                &LangChain.Message.ToolCall.new!(
                  Map.take(&1, ["status", "type", "call_id", "name", "arguments", "index"])
                )
              )
            )
          else
            message_params
          end

        message_params =
          if is_binary(message.text) && String.trim(message.text) != "" do
            Map.put(message_params, :content, message.text)
          else
            message_params
          end

        langchain_message = LangChain.Message.new_assistant!(message_params)

        if message.tool_results && !Enum.empty?(message.tool_results) do
          [
            langchain_message,
            LangChain.Message.new_tool_result!(%{
              tool_results:
                Enum.map(
                  message.tool_results,
                  &LangChain.Message.ToolResult.new!(
                    Map.take(&1, [
                      "type",
                      "tool_call_id",
                      "name",
                      "content",
                      "display_text",
                      "is_error",
                      "options"
                    ])
                  )
                )
            })
          ]
        else
          [langchain_message]
        end

      %{source: :user, text: text} ->
        [LangChain.Message.new_user!(text)]
    end)
  end
end
