defmodule JumpstartAi.Chat.OngoingInstruction do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Chat,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "ongoing_instructions"
    repo JumpstartAi.Repo
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

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:instruction, :trigger_conditions, :is_active]
      change relate_actor(:user)
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

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
      allow_nil? false
    end
  end
end