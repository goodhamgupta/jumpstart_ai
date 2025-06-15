defmodule JumpstartAi.Accounts.Email do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "emails"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read]

    read :read_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    create :create_from_gmail do
      accept [
        :gmail_id,
        :thread_id,
        :subject,
        :from_email,
        :from_name,
        :to_email,
        :date,
        :snippet,
        :body_text,
        :body_html,
        :label_ids,
        :user_id
      ]

      argument :user_id, :uuid, allow_nil?: false
      change set_attribute(:user_id, arg(:user_id))

      upsert? true
      upsert_identity :unique_gmail_id_per_user
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :gmail_id, :string do
      allow_nil? false
      public? true
    end

    attribute :thread_id, :string do
      allow_nil? true
      public? true
    end

    attribute :subject, :string do
      allow_nil? true
      public? true
    end

    attribute :from_email, :string do
      allow_nil? true
      public? true
    end

    attribute :from_name, :string do
      allow_nil? true
      public? true
    end

    attribute :to_email, :string do
      allow_nil? true
      public? true
    end

    attribute :date, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :snippet, :string do
      allow_nil? true
      public? true
    end

    attribute :body_text, :string do
      allow_nil? true
      public? true
    end

    attribute :body_html, :string do
      allow_nil? true
      public? true
    end

    attribute :label_ids, {:array, :string} do
      allow_nil? true
      public? true
      default []
    end

    timestamps()
  end

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_gmail_id_per_user, [:gmail_id, :user_id]
  end
end
