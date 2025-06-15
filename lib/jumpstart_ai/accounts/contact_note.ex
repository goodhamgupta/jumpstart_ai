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
        :source,
        :external_id,
        :content,
        :note_type,
        :external_created_at,
        :external_updated_at
      ]
    end

    create :create_from_hubspot do
      argument :hubspot_note_data, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_external_note

      change fn changeset, _context ->
        note_data = Ash.Changeset.get_argument(changeset, :hubspot_note_data)

        changeset
        |> Ash.Changeset.change_attribute(:contact_id, note_data.contact_id)
        |> Ash.Changeset.change_attribute(:source, "hubspot")
        |> Ash.Changeset.change_attribute(:external_id, note_data.hubspot_note_id)
        |> Ash.Changeset.change_attribute(:content, note_data.content)
        |> Ash.Changeset.change_attribute(:note_type, note_data.note_type || "NOTE")
        |> Ash.Changeset.change_attribute(:external_created_at, note_data.created_at)
        |> Ash.Changeset.change_attribute(:external_updated_at, note_data.updated_at)
      end

      upsert_fields [
        :content,
        :note_type,
        :external_updated_at
      ]
    end

    update :update do
      accept [
        :content,
        :note_type,
        :external_updated_at
      ]
    end

    read :get_by_contact do
      argument :contact_id, :uuid, allow_nil?: false
      filter expr(contact_id == ^arg(:contact_id))
    end

    read :search_content do
      argument :query, :string, allow_nil?: false
    end

    read :get_by_external_id do
      argument :external_id, :string, allow_nil?: false
      argument :source, :string, allow_nil?: false
      get? true
      filter expr(external_id == ^arg(:external_id) and source == ^arg(:source))
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

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string do
      allow_nil? false
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

    attribute :external_created_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :external_updated_at, :utc_datetime_usec do
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
    identity :unique_external_note, [:contact_id, :source, :external_id]
  end
end
