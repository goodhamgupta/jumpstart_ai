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

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      message = changeset.data

      messages =
        JumpstartAi.Chat.Message
        |> Ash.Query.filter(conversation_id == ^message.conversation_id)
        |> Ash.Query.filter(id != ^message.id)
        |> Ash.Query.select([:text, :source, :tool_calls, :tool_results])
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
            custom_context: Map.new(Ash.Context.to_opts(context))
          })
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(system_prompt)
      |> LLMChain.add_messages(message_chain)
      # add the names of tools you want available in your conversation here.
      # i.e tools: [:lookup_weather]
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

          if content != "" do
            JumpstartAi.Chat.Message
            |> Ash.Changeset.for_create(
              :upsert_response,
              %{
                id: new_message_id,
                response_to_id: message.id,
                conversation_id: message.conversation_id,
                text: content
              },
              actor: %AshAi{}
            )
            |> Ash.create!()
          end
        end,
        on_message_processed: fn _chain, data ->
          text = to_text(data.content)

          if (data.tool_calls && Enum.any?(data.tool_calls)) ||
               (data.tool_results && Enum.any?(data.tool_results)) ||
               text != "" do
            JumpstartAi.Chat.Message
            |> Ash.Changeset.for_create(
              :upsert_response,
              %{
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
              },
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
        langchain_message =
          LangChain.Message.new_assistant!(%{
            content: message.text,
            tool_calls:
              message.tool_calls &&
                Enum.map(
                  message.tool_calls,
                  &LangChain.Message.ToolCall.new!(
                    Map.take(&1, ["status", "type", "call_id", "name", "arguments", "index"])
                  )
                )
          })

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
