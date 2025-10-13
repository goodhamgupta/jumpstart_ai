defmodule JumpstartAi.Chat.Task do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Chat,
    extensions: [AshOban],
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub]

  oban do
    triggers do
      trigger :continue_task do
        action :continue
        queue :task_continuation
        lock_for_update? false
        worker_module_name JumpstartAi.Workers.TaskContinuation
        scheduler_module_name JumpstartAi.Workers.TaskContinuationScheduler
        where expr(status == :waiting_for_response)
      end
    end
  end

  postgres do
    table "tasks"
    repo JumpstartAi.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :description, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:active, :waiting_for_response, :completed, :failed]
      default :active
      public? true
    end

    attribute :context, :map do
      public? true
    end

    attribute :next_action, :string do
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:description, :context, :next_action]
      argument :conversation_id, :uuid, allow_nil?: false
      change relate_actor(:user)
      change set_attribute(:conversation_id, arg(:conversation_id))
    end

    update :update_status do
      accept [:status, :context, :next_action]
    end

    update :continue do
      accept []
      transaction? false
      require_atomic? false
    end

    read :active_for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status in [:active, :waiting_for_response])
    end

    read :active_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id) and status in [:active, :waiting_for_response])
    end

    read :active_for_current_user do
      filter expr(user_id == ^actor(:id) and status in [:active, :waiting_for_response])
    end
  end

  pub_sub do
    module JumpstartAiWeb.Endpoint
    prefix "chat"

    publish_all :create, ["tasks", :user_id] do
      transform & &1.data
    end

    publish_all :update, ["tasks", :user_id] do
      transform & &1.data
    end
  end

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
      allow_nil? false
    end

    belongs_to :conversation, JumpstartAi.Chat.Conversation do
      public? true
      allow_nil? false
    end
  end
end
