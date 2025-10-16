defmodule JumpstartAi.Chat.OngoingInstruction do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Chat,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshAi]

  postgres do
    table "ongoing_instructions"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:instruction, :trigger_conditions, :is_active]
      change relate_actor(:user)
      change JumpstartAi.Chat.OngoingInstruction.Changes.ParseTriggerConditions
    end

    update :update do
      accept [:instruction, :trigger_conditions, :is_active, :last_triggered_at]
    end

    update :mark_triggered do
      accept []
      change set_attribute(:last_triggered_at, &DateTime.utc_now/0)
    end

    read :active_for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and is_active == true)
    end

    read :active_for_current_user do
      filter expr(user_id == ^actor(:id) and is_active == true)
    end

    action :parse_trigger_conditions, JumpstartAi.Chat.OngoingInstruction.Types.TriggerConditions do
      description """
      Parses a natural language instruction into structured trigger conditions.
      Returns a typed struct with the trigger type and any additional parameters.
      """

      argument :instruction, :string do
        allow_nil? false
        description "The natural language instruction to parse"
      end

      run prompt(
        fn _input, _context ->
          LangChain.ChatModels.ChatOpenAI.new!(%{
            model: "gpt-4o-mini",
            temperature: 0.0
          })
        end,
        prompt: """
        You are parsing a user instruction into trigger conditions.

        SUPPORTED TRIGGERS:
        - "new_email_from_unknown_sender": Email from sender not in contacts
        - "new_contact_created": New contact created
        - "new_calendar_event": New calendar event created
        - "email_from_sender": Email from specific sender (requires "sender_email" field)

        EXAMPLES:
        Input: "When I receive an email from an unknown sender, create a HubSpot contact"
        Output: trigger="new_email_from_unknown_sender"

        Input: "When I receive an email from john@example.com, add to CRM"
        Output: trigger="email_from_sender", sender_email="john@example.com"

        Parse this instruction: <%= @input.arguments.instruction %>
        """,
        tools: false
      )
    end
  end

  pub_sub do
    module JumpstartAiWeb.Endpoint
    prefix "chat"

    publish_all :create, ["ongoing_instructions", :user_id] do
      transform & &1.data
    end

    publish_all :update, ["ongoing_instructions", :user_id] do
      transform & &1.data
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :instruction, :string do
      allow_nil? false
      public? true
    end

    attribute :trigger_conditions, :map do
      public? true
    end

    attribute :is_active, :boolean do
      default true
      public? true
    end

    attribute :last_triggered_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
      allow_nil? false
    end
  end
end
