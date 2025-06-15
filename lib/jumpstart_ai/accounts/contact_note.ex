defmodule JumpstartAi.Accounts.ContactNote do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "contact_notes"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :contact_id,
        :hubspot_note_id,
        :content,
        :note_type,
        :hubspot_created_at,
        :hubspot_updated_at
      ]
    end

    create :create_from_hubspot do
      argument :hubspot_note_data, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_hubspot_note

      change fn changeset, _context ->
        note_data = Ash.Changeset.get_argument(changeset, :hubspot_note_data)
        
        changeset
        |> Ash.Changeset.change_attribute(:hubspot_note_id, note_data.hubspot_note_id)
        |> Ash.Changeset.change_attribute(:content, note_data.content)
        |> Ash.Changeset.change_attribute(:note_type, note_data.note_type || "NOTE")
        |> Ash.Changeset.change_attribute(:hubspot_created_at, note_data.created_at)
        |> Ash.Changeset.change_attribute(:hubspot_updated_at, note_data.updated_at)
      end

      upsert_fields [
        :content,
        :note_type,
        :hubspot_updated_at
      ]
    end

    update :update do
      accept [
        :content,
        :note_type,
        :hubspot_updated_at
      ]
    end

    read :get_by_contact do
      argument :contact_id, :uuid, allow_nil?: false
      filter expr(contact_id == ^arg(:contact_id))
    end

    read :search_content do
      argument :query, :string, allow_nil?: false
    end

    read :get_by_hubspot_id do
      argument :hubspot_note_id, :string, allow_nil?: false
      get? true
      filter expr(hubspot_note_id == ^arg(:hubspot_note_id))
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

    attribute :contact_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :hubspot_note_id, :string do
      allow_nil? true
      public? true
    end

    attribute :content, :string do
      allow_nil? false
      public? true
    end

    attribute :note_type, :string do
      allow_nil? true
      public? true
      default "NOTE"
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
    belongs_to :contact, JumpstartAi.Accounts.Contact do
      public? true
    end
  end

  identities do
    identity :unique_hubspot_note, [:contact_id, :hubspot_note_id]
  end

end