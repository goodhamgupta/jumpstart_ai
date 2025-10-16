defmodule JumpstartAi.Chat.Conversation.Changes.GenerateName do
  use Ash.Resource.Change
  require Ash.Query
  import Ash.Expr

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      conversation = changeset.data

      messages =
        JumpstartAi.Chat.Message
        |> Ash.Query.do_filter(expr(conversation_id == ^conversation.id))
        |> Ash.Query.limit(10)
        |> Ash.Query.select([:text, :source])
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read!()

      system_prompt =
        LangChain.Message.new_system!("""
        Provide a short name for the current conversation.
        2-8 words, preferring more succinct names.
        RESPOND WITH ONLY THE NEW CONVERSATION NAME.
        """)

      message_chain =
        Enum.map(messages, fn message ->
          if message.source == :agent do
            LangChain.Message.new_assistant!(message.text)
          else
            LangChain.Message.new_user!(message.text)
          end
        end)

      %{
        llm:
          ChatOpenAI.new!(%{
            model: "gpt-4.1-mini-2025-04-14",
            custom_context: Map.new(Ash.Context.to_opts(context))
          }),
        verbose?: true
      }
      |> LLMChain.new!()
      |> LLMChain.add_message(system_prompt)
      |> LLMChain.add_messages(message_chain)
      |> LLMChain.run(mode: :while_needs_response)
      |> case do
        {:ok,
         %LangChain.Chains.LLMChain{
           last_message: %{content: content}
         }} ->
          title =
            cond do
              is_binary(content) ->
                String.trim(content)

              is_list(content) ->
                content
                |> Enum.reduce("", fn
                  %LangChain.Message.ContentPart{type: :text, content: c}, acc
                  when is_binary(c) ->
                    acc <> c

                  _, acc ->
                    acc
                end)
                |> String.trim()

              true ->
                ""
            end

          if title != "" do
            Ash.Changeset.force_change_attribute(changeset, :title, title)
          else
            changeset
          end

        {:error, _, error} ->
          {:error, error}
      end
    end)
  end
end
