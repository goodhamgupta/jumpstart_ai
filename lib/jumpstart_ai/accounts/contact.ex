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
        :source,
        :external_id,
        :email,
        :firstname,
        :lastname,
        :phone,
        :company,
        :lifecycle_stage,
        :notes_summary,
        :external_created_at,
        :external_updated_at
      ]
    end

    create :create_from_hubspot do
      argument :hubspot_data, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_external_contact

      change fn changeset, _context ->
        hubspot_data = Ash.Changeset.get_argument(changeset, :hubspot_data)

        changeset
        |> Ash.Changeset.change_attribute(:user_id, hubspot_data.user_id)
        |> Ash.Changeset.change_attribute(:source, "hubspot")
        |> Ash.Changeset.change_attribute(:external_id, hubspot_data.external_id)
        |> Ash.Changeset.change_attribute(:email, hubspot_data.email)
        |> Ash.Changeset.change_attribute(:firstname, hubspot_data.firstname)
        |> Ash.Changeset.change_attribute(:lastname, hubspot_data.lastname)
        |> Ash.Changeset.change_attribute(:phone, hubspot_data.phone)
        |> Ash.Changeset.change_attribute(:company, hubspot_data.company)
        |> Ash.Changeset.change_attribute(:lifecycle_stage, hubspot_data.lifecycle_stage)
        |> Ash.Changeset.change_attribute(:external_created_at, hubspot_data.created_at)
        |> Ash.Changeset.change_attribute(:external_updated_at, hubspot_data.updated_at)
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
        :external_updated_at
      ]
    end

    create :create_from_google do
      argument :google_data, :map, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      upsert? true
      upsert_identity :unique_external_contact

      change fn changeset, _context ->
        google_data = Ash.Changeset.get_argument(changeset, :google_data)
        user_id = Ash.Changeset.get_argument(changeset, :user_id)

        changeset
        |> Ash.Changeset.change_attribute(:user_id, user_id)
        |> Ash.Changeset.change_attribute(:source, "google")
        |> Ash.Changeset.change_attribute(:external_id, google_data.google_id)
        |> Ash.Changeset.change_attribute(:email, google_data.email)
        |> Ash.Changeset.change_attribute(:firstname, google_data.firstname)
        |> Ash.Changeset.change_attribute(:lastname, google_data.lastname)
        |> Ash.Changeset.change_attribute(:phone, google_data.phone)
        |> Ash.Changeset.change_attribute(:company, google_data.company)
        |> Ash.Changeset.change_attribute(:external_created_at, google_data.created_at)
        |> Ash.Changeset.change_attribute(:external_updated_at, google_data.updated_at)
        |> Ash.Changeset.change_attribute(
          :notes_summary,
          generate_google_notes_summary(google_data)
        )
      end

      upsert_fields [
        :email,
        :firstname,
        :lastname,
        :phone,
        :company,
        :notes_summary,
        :external_updated_at
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
        :external_updated_at
      ]
    end

    read :search_by_name do
      argument :query, :string, allow_nil?: false
    end

    read :get_by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :get_by_external_id do
      argument :external_id, :string, allow_nil?: false
      argument :source, :string, allow_nil?: false
      get? true
      filter expr(external_id == ^arg(:external_id) and source == ^arg(:source))
    end

    read :search_by_email do
      argument :email, :string, allow_nil?: false
      get? true
      filter expr(email == ^arg(:email))
    end

    read :find_contact do
      description "Find contacts by name, email, or company"
      argument :query, :string, allow_nil?: false

      filter expr(
               ilike(firstname, ^arg(:query)) or
                 ilike(lastname, ^arg(:query)) or
                 ilike(email, ^arg(:query)) or
                 ilike(company, ^arg(:query))
             )
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

    attribute :source, :string do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string do
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
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
    end

    has_many :contact_notes, JumpstartAi.Accounts.ContactNote do
      public? true
    end
  end

  identities do
    identity :unique_external_contact, [:user_id, :source, :external_id]
    identity :unique_user_email, [:user_id, :email]
  end

  # Helper function to generate a summary for vector search from HubSpot data
  defp generate_notes_summary(hubspot_data) do
    parts = []

    parts =
      if hubspot_data.firstname,
        do: ["First name: #{hubspot_data.firstname}" | parts],
        else: parts

    parts =
      if hubspot_data.lastname, do: ["Last name: #{hubspot_data.lastname}" | parts], else: parts

    parts = if hubspot_data.email, do: ["Email: #{hubspot_data.email}" | parts], else: parts
    parts = if hubspot_data.company, do: ["Company: #{hubspot_data.company}" | parts], else: parts

    parts =
      if hubspot_data.lifecycle_stage,
        do: ["Stage: #{hubspot_data.lifecycle_stage}" | parts],
        else: parts

    parts = if hubspot_data.phone, do: ["Phone: #{hubspot_data.phone}" | parts], else: parts

    Enum.join(parts, ". ")
  end

  # Helper function to generate a summary for vector search from Google data
  defp generate_google_notes_summary(google_data) do
    parts = []

    parts =
      if google_data.firstname, do: ["First name: #{google_data.firstname}" | parts], else: parts

    parts =
      if google_data.lastname, do: ["Last name: #{google_data.lastname}" | parts], else: parts

    parts = if google_data.email, do: ["Email: #{google_data.email}" | parts], else: parts
    parts = if google_data.company, do: ["Company: #{google_data.company}" | parts], else: parts
    parts = if google_data.phone, do: ["Phone: #{google_data.phone}" | parts], else: parts

    Enum.join(parts, ". ")
  end
end
