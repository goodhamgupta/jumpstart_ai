defmodule JumpstartAi.Chat.Message.Changes.Respond do
  use Ash.Resource.Change
  require Ash.Query

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
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      message = changeset.data

      messages =
        JumpstartAi.Chat.Message
        |> Ash.Query.filter(conversation_id == ^message.conversation_id)
        |> Ash.Query.filter(id != ^message.id)
        |> Ash.Query.select([:text, :source, :tool_calls, :tool_results, :reasoning_content])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read!()
        |> Enum.concat([%{source: :user, text: message.text}])

      system_prompt =
        LangChain.Message.new_system!("""
        You are a helpful AI assistant for a Financial Advisor application.
        Your job is to use the tools at your disposal to assist the user with managing emails, contacts, calendar events, and notes.

        IMPORTANT EMAIL SAFETY RULES:
        - NEVER send emails directly without user review and explicit confirmation
        - ALWAYS use draft_email first when composing any email
        - ALWAYS show draft details and ask for confirmation before sending with send_email_with_draft
        - Example workflow: "I've drafted this email for you. Would you like me to send it?"
        - Use list_drafts to help users review and manage their pending emails
        - Use send_email_with_draft (with draft_id) as the ONLY way to send emails

        Available capabilities:
        - Search and analyze emails, contacts, notes, and calendar events semantically
        - List recent emails, contacts, notes, and calendar events for quick overview
        - Create email drafts for user review and send approved drafts
        - Create calendar events and schedule meetings with attendees
        - Find relevant information using AI-powered search
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
          :find_contact
        ],
        actor: context.actor
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
