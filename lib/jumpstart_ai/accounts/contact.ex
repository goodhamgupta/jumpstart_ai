defmodule JumpstartAi.Accounts.Contact do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "contacts"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :user_id,
        :hubspot_id,
        :email,
        :firstname,
        :lastname,
        :phone,
        :company,
        :lifecycle_stage,
        :notes_summary,
        :hubspot_created_at,
        :hubspot_updated_at
      ]
    end

    create :create_from_hubspot do
      argument :hubspot_data, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_hubspot_contact

      change fn changeset, _context ->
        hubspot_data = Ash.Changeset.get_argument(changeset, :hubspot_data)
        
        changeset
        |> Ash.Changeset.change_attribute(:user_id, hubspot_data.user_id)
        |> Ash.Changeset.change_attribute(:hubspot_id, hubspot_data.hubspot_id)
        |> Ash.Changeset.change_attribute(:email, hubspot_data.email)
        |> Ash.Changeset.change_attribute(:firstname, hubspot_data.firstname)
        |> Ash.Changeset.change_attribute(:lastname, hubspot_data.lastname)
        |> Ash.Changeset.change_attribute(:phone, hubspot_data.phone)
        |> Ash.Changeset.change_attribute(:company, hubspot_data.company)
        |> Ash.Changeset.change_attribute(:lifecycle_stage, hubspot_data.lifecycle_stage)
        |> Ash.Changeset.change_attribute(:hubspot_created_at, hubspot_data.created_at)
        |> Ash.Changeset.change_attribute(:hubspot_updated_at, hubspot_data.updated_at)
        |> Ash.Changeset.change_attribute(:notes_summary, generate_notes_summary(hubspot_data))
      end

      upsert_fields [
        :email,
        :firstname,
        :lastname,
        :phone,
        :company,
        :lifecycle_stage,
        :notes_summary,
        :hubspot_updated_at
      ]
    end

    update :update do
      accept [
        :email,
        :firstname,
        :lastname,
        :phone,
        :company,
        :lifecycle_stage,
        :notes_summary,
        :hubspot_updated_at
      ]
    end

    read :search_by_name do
      argument :query, :string, allow_nil?: false
    end

    read :get_by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :get_by_hubspot_id do
      argument :hubspot_id, :string, allow_nil?: false
      get? true
      filter expr(hubspot_id == ^arg(:hubspot_id))
    end

    read :search_by_email do
      argument :email, :string, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email))
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :hubspot_id, :string do
      allow_nil? false
      public? true
    end

    attribute :email, :string do
      allow_nil? true
      public? true
    end

    attribute :firstname, :string do
      allow_nil? true
      public? true
    end

    attribute :lastname, :string do
      allow_nil? true
      public? true
    end

    attribute :phone, :string do
      allow_nil? true
      public? true
    end

    attribute :company, :string do
      allow_nil? true
      public? true
    end

    attribute :lifecycle_stage, :string do
      allow_nil? true
      public? true
    end

    attribute :notes_summary, :string do
      allow_nil? true
      public? true
    end

    attribute :hubspot_created_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :hubspot_updated_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
    end

    has_many :contact_notes, JumpstartAi.Accounts.ContactNote do
      public? true
    end
  end

  identities do
    identity :unique_hubspot_contact, [:user_id, :hubspot_id]
    identity :unique_user_email, [:user_id, :email]
  end


  # Helper function to generate a summary for vector search
  defp generate_notes_summary(hubspot_data) do
    parts = []
    
    parts = if hubspot_data.firstname, do: ["First name: #{hubspot_data.firstname}" | parts], else: parts
    parts = if hubspot_data.lastname, do: ["Last name: #{hubspot_data.lastname}" | parts], else: parts
    parts = if hubspot_data.email, do: ["Email: #{hubspot_data.email}" | parts], else: parts
    parts = if hubspot_data.company, do: ["Company: #{hubspot_data.company}" | parts], else: parts
    parts = if hubspot_data.lifecycle_stage, do: ["Stage: #{hubspot_data.lifecycle_stage}" | parts], else: parts
    parts = if hubspot_data.phone, do: ["Phone: #{hubspot_data.phone}" | parts], else: parts

    Enum.join(parts, ". ")
  end
end