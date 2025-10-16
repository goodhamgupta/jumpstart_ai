defmodule JumpstartAi.Chat.Message do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Chat,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  oban do
    triggers do
      trigger :respond do
        actor_persister JumpstartAi.AiAgentActorPersister
        action :respond
        queue :chat_responses
        lock_for_update? false
        scheduler_cron false
        read_action :read
        worker_read_action :read
        worker_module_name JumpstartAi.Chat.Message.Workers.Respond
        # No scheduler_module_name needed when scheduler_cron is false
        where expr(needs_response)
      end
    end
  end

  postgres do
    table "messages"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :for_conversation do
      pagination keyset?: true, required?: false
      argument :conversation_id, :uuid, allow_nil?: false

      prepare build(default_sort: [inserted_at: :desc])
      filter expr(conversation_id == ^arg(:conversation_id) and complete == true)
    end

    create :create do
      accept [:text, :mentions]

      argument :conversation_id, :uuid do
        public? false
      end

      change JumpstartAi.Chat.Message.Changes.CreateConversationIfNotProvided
      change JumpstartAi.Chat.Message.Changes.ParseMentions
      change run_oban_trigger(:respond)
    end

    update :respond do
      accept []
      require_atomic? false
      transaction? false
      change JumpstartAi.Chat.Message.Changes.Respond
    end

    create :upsert_response do
      upsert? true
      upsert_identity :primary_key
      accept [:id, :response_to_id, :conversation_id]
      argument :complete, :boolean, default: false
      argument :text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]
      argument :reasoning_content, :string, constraints: [trim?: false, allow_empty?: true]
      argument :tool_calls, {:array, :map}
      argument :tool_results, {:array, :map}

      # if creating, set the attributes to the provided values
      change set_attribute(:text, arg(:text))
      change set_attribute(:complete, arg(:complete))
      change set_attribute(:source, :agent)
      change set_attribute(:reasoning_content, arg(:reasoning_content))
      change set_attribute(:tool_results, arg(:tool_results))
      change set_attribute(:tool_calls, arg(:tool_calls))

      # if updating
      #   if complete, set the text to the provided text
      #   if streaming still, append the text to the existing text
      change atomic_update(
               :text,
               {:atomic,
                expr(
                  if ^arg(:complete) do
                    fragment("EXCLUDED.\"text\"")
                  else
                    fragment("COALESCE(m0.\"text\", '') || EXCLUDED.\"text\"")
                  end
                )}
             )

      change atomic_update(
               :tool_calls,
               {:atomic,
                expr(
                  if not is_nil(^arg(:tool_calls)) do
                    fragment(
                      "? || ?",
                      ^atomic_ref(:tool_calls),
                      type(
                        ^arg(:tool_calls),
                        {:array, :map}
                      )
                    )
                  else
                    ^atomic_ref(:tool_calls)
                  end
                )}
             )

      change atomic_update(
               :tool_results,
               {:atomic,
                expr(
                  if not is_nil(^arg(:tool_results)) do
                    fragment(
                      "? || ?",
                      ^atomic_ref(:tool_results),
                      type(
                        ^arg(:tool_results),
                        {:array, :map}
                      )
                    )
                  else
                    ^atomic_ref(:tool_results)
                  end
                )}
             )

      change atomic_update(
               :reasoning_content,
               {:atomic,
                expr(
                  if ^arg(:complete) do
                    fragment("EXCLUDED.\"reasoning_content\"")
                  else
                    fragment(
                      "COALESCE(m0.\"reasoning_content\", '') || COALESCE(EXCLUDED.\"reasoning_content\", '')"
                    )
                  end
                )}
             )

      # on update, update these fields
      upsert_fields [:text, :complete, :tool_calls, :tool_results, :reasoning_content]
    end
  end

  pub_sub do
    module JumpstartAiWeb.Endpoint
    prefix "chat"

    publish :create, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          reasoning_content: message.reasoning_content
        }
      end
    end

    publish :upsert_response, ["messages", :conversation_id] do
      transform fn %{data: message} ->
        %{
          text: message.text,
          id: message.id,
          source: message.source,
          complete: message.complete,
          reasoning_content: message.reasoning_content
        }
      end
    end
  end

  attributes do
    timestamps()
    uuid_v7_primary_key :id, writable?: true

    attribute :text, :string do
      constraints allow_empty?: true, trim?: false
      public? true
      allow_nil? false
    end

    attribute :reasoning_content, :string do
      constraints allow_empty?: true, trim?: false
      public? true
    end

    attribute :tool_calls, {:array, :map}
    attribute :tool_results, {:array, :map}

    attribute :source, JumpstartAi.Chat.Message.Types.Source do
      allow_nil? false
      public? true
      default :user
    end

    attribute :complete, :boolean do
      allow_nil? false
      default true
    end

    attribute :mentions, {:array, :map} do
      allow_nil? true
      default []
      public? true
    end
  end

  relationships do
    belongs_to :conversation, JumpstartAi.Chat.Conversation do
      public? true
      allow_nil? false
    end

    belongs_to :response_to, __MODULE__ do
      public? true
    end

    has_one :response, __MODULE__ do
      public? true
      destination_attribute :response_to_id
    end
  end

  calculations do
    calculate :needs_response, :boolean do
      calculation expr(source == :user and not exists(response))
    end
  end

  identities do
    identity :primary_key, [:id]
  end
end
