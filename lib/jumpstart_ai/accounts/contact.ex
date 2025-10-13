defmodule JumpstartAi.Accounts.Contact do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi]

  alias JumpstartAi.TextUtils

  postgres do
    table "contacts"
    repo JumpstartAi.Repo
  end

  vectorize do
    # Combine contact metadata and summary into a single vector for semantic search
    full_text do
      text fn contact ->
        metadata = """
        Contact: #{TextUtils.clean_text(contact.firstname || "")} #{TextUtils.clean_text(contact.lastname || "")}
        Email: #{contact.email || "No email"}
        Company: #{TextUtils.clean_text(contact.company || "No company")}
        Phone: #{contact.phone || "No phone"}
        Lifecycle Stage: #{contact.lifecycle_stage || "Unknown"}
        Source: #{contact.source || "Unknown"}
        """

        notes_content = TextUtils.clean_and_truncate(contact.notes_summary || "", 4000)

        metadata <> "\n\nNotes Summary:\n" <> notes_content
      end

      used_attributes [
        :firstname,
        :lastname,
        :email,
        :company,
        :phone,
        :lifecycle_stage,
        :source,
        :notes_summary
      ]
    end

    strategy :manual
    embedding_model JumpstartAi.OpenAiEmbeddingModel
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

      # Automatic vectorization after contact creation/update - only if data changed
      change after_action(fn changeset, contact, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :firstname,
                 :lastname,
                 :email,
                 :company,
                 :phone,
                 :lifecycle_stage,
                 :source,
                 :notes_summary
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changing_attribute?(changeset, field)
                 end)

               if data_changed do
                 case contact
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(
                        actor: %AshAi{},
                        authorize?: false
                      ) do
                   {:ok, updated_contact} ->
                     {:ok, updated_contact}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for contact #{contact.id} from HubSpot: #{inspect(error)}"
                     )

                     {:ok, contact}
                 end
               else
                 {:ok, contact}
               end
             end)

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

      # Automatic vectorization after contact creation/update - only if data changed
      change after_action(fn changeset, contact, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :firstname,
                 :lastname,
                 :email,
                 :company,
                 :phone,
                 :lifecycle_stage,
                 :source,
                 :notes_summary
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changing_attribute?(changeset, field)
                 end)

               if data_changed do
                 case contact
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(actor: %AshAi{}, authorize?: false) do
                   {:ok, updated_contact} ->
                     {:ok, updated_contact}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for contact #{contact.id} from Google: #{inspect(error)}"
                     )

                     {:ok, contact}
                 end
               else
                 {:ok, contact}
               end
             end)

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

      require_atomic? false

      # Trigger manual vectorization after update - only if vectorized fields changed
      change after_action(fn changeset, contact, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :firstname,
                 :lastname,
                 :email,
                 :company,
                 :phone,
                 :lifecycle_stage,
                 :source,
                 :notes_summary
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changing_attribute?(changeset, field)
                 end)

               if data_changed do
                 case contact
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(actor: %AshAi{}, authorize?: false) do
                   {:ok, updated_contact} ->
                     {:ok, updated_contact}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for contact #{contact.id}: #{inspect(error)}"
                     )

                     {:ok, contact}
                 end
               else
                 {:ok, contact}
               end
             end)
    end

    update :vectorize do
      accept []
      change AshAi.Changes.Vectorize
      require_atomic? false
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

    read :search_for_mention do
      argument :query, :string, allow_nil?: false

      argument :limit, :integer do
        allow_nil? true
        default 5
      end

      argument :user_id, :uuid, allow_nil?: false

      manual fn query, _, _ ->
        search_query = query.arguments[:query]
        user_id = query.arguments[:user_id]
        limit = query.arguments[:limit] || 5

        # Use raw SQL for case-insensitive search
        sql = """
        SELECT id, firstname, lastname, email, company
        FROM contacts
        WHERE user_id = $1
          AND (
            firstname ILIKE $2 OR
            lastname ILIKE $2 OR
            email ILIKE $2 OR
            company ILIKE $2
          )
        ORDER BY firstname ASC, lastname ASC
        LIMIT $3
        """

        search_pattern = "%#{search_query}%"

        case JumpstartAi.Repo.query(sql, [
               Ecto.UUID.dump!(user_id),
               search_pattern,
               limit
             ]) do
          {:ok, %{rows: rows}} ->
            # Convert rows to proper Ash resource structs
            contacts =
              Enum.map(rows, fn [id_binary, firstname, lastname, email, company] ->
                {:ok, id} = Ecto.UUID.load(id_binary)

                # Create a proper struct with all required fields
                struct(JumpstartAi.Accounts.Contact, %{
                  id: id,
                  firstname: firstname,
                  lastname: lastname,
                  email: email,
                  company: company,
                  __metadata__: %{},
                  calculations: %{},
                  aggregates: %{}
                })
              end)

            {:ok, contacts}

          {:error, error} ->
            {:error, error}
        end
      end
    end

    action :search_contacts, {:array, :map} do
      description """
      Unified contact search that tries both field-based and semantic search automatically.
      First performs exact field matching, then falls back to semantic search if few results found.
      """

      argument :query, :string do
        allow_nil? false
        description "Search query - can be name, email, company, or natural language description"
      end

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of results to return (default: 10)"
      end

      run fn input, context ->
        user_id = context.actor.id
        search_query = input.arguments.query
        limit = input.arguments.limit || 10

        # First try field-based search
        field_search_pattern = "%#{search_query}%"

        field_sql = """
        SELECT id, firstname, lastname, email, company, phone, lifecycle_stage, source, notes_summary
        FROM contacts
        WHERE user_id = $1
          AND (
            firstname ILIKE $2 OR
            lastname ILIKE $2 OR
            email ILIKE $2 OR
            company ILIKE $2
          )
        ORDER BY external_updated_at DESC
        LIMIT $3
        """

        case JumpstartAi.Repo.query(field_sql, [
               Ecto.UUID.dump!(user_id),
               field_search_pattern,
               limit
             ]) do
          {:ok, %{rows: field_rows}} when length(field_rows) >= 3 ->
            # Good field results, use them
            format_contact_results(field_rows)

          {:ok, %{rows: field_rows}} ->
            # Few field results, try semantic search too
            case semantic_search(user_id, search_query, limit - length(field_rows)) do
              {:ok, semantic_results} ->
                # Combine and deduplicate results
                all_results =
                  (field_rows ++ semantic_results)
                  |> Enum.uniq_by(fn [id | _] -> id end)
                  |> Enum.take(limit)

                format_contact_results(all_results)

              {:error, _} ->
                # Fall back to field results only
                format_contact_results(field_rows)
            end

          {:error, error} ->
            {:error, "Failed to search contacts: #{inspect(error)}"}
        end
      end
    end

    action :semantic_search_contacts, {:array, :map} do
      description """
      Semantic search for contacts using vector similarity. Searches contact information, notes summary, and metadata for semantically similar content.
      """

      argument :query, :string do
        allow_nil? false
        description "The search query to find semantically similar contacts"
      end

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of results to return (default: 10)"
      end

      argument :similarity_threshold, :float do
        allow_nil? true
        default 0.7
        description "Minimum similarity score (0.0 to 1.0, default: 0.7)"
      end

      run fn input, context ->
        user_id = context.actor.id
        search_query = input.arguments.query
        limit = input.arguments.limit || 10
        similarity_threshold = input.arguments.similarity_threshold || 0.7

        # Generate embedding for the search query
        case JumpstartAi.OpenAiEmbeddingModel.generate([search_query], []) do
          {:ok, [search_vector]} ->
            # Use raw SQL for now since Ash expressions are complex with vectors
            sql_query = """
            SELECT id, firstname, lastname, email, company, phone, lifecycle_stage, source, notes_summary
            FROM contacts 
            WHERE user_id = $1 
              AND full_text_vector IS NOT NULL 
              AND (full_text_vector <=> $2) >= $3
            ORDER BY (full_text_vector <=> $2) DESC
            LIMIT $4
            """

            case JumpstartAi.Repo.query(sql_query, [
                   Ecto.UUID.dump!(user_id),
                   search_vector,
                   similarity_threshold,
                   limit
                 ]) do
              {:ok, %{rows: rows}} ->
                formatted_contacts =
                  Enum.map(rows, fn [
                                      id,
                                      firstname,
                                      lastname,
                                      email,
                                      company,
                                      phone,
                                      lifecycle_stage,
                                      source,
                                      notes_summary
                                    ] ->
                    %{
                      "id" => Ecto.UUID.load!(id),
                      "name" => "#{firstname || ""} #{lastname || ""}" |> String.trim(),
                      "email" => email,
                      "company" => company,
                      "phone" => phone,
                      "lifecycle_stage" => lifecycle_stage,
                      "source" => source,
                      "notes_summary" =>
                        case notes_summary do
                          nil -> nil
                          text when byte_size(text) > 200 -> String.slice(text, 0, 200) <> "..."
                          text -> text
                        end
                    }
                  end)

                {:ok, formatted_contacts}

              {:error, error} ->
                {:error, "Failed to search contacts: #{inspect(error)}"}
            end

          {:error, error} ->
            {:error, "Failed to generate search embedding: #{inspect(error)}"}
        end
      end
    end

    action :list_contacts, {:array, :map} do
      description """
      Lists the latest contacts for the user. Returns the 10 most recent contacts with key details.
      """

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of contacts to return (default: 10)"
      end

      run fn input, context ->
        user_id = context.actor.id
        limit = input.arguments[:limit] || 10

        case JumpstartAi.Accounts.Contact
             |> Ash.Query.for_read(:get_by_user, %{user_id: user_id})
             |> Ash.Query.select([
               :firstname,
               :lastname,
               :email,
               :company,
               :phone,
               :lifecycle_stage,
               :source,
               :external_updated_at
             ])
             |> Ash.Query.sort(external_updated_at: :desc)
             |> Ash.Query.limit(limit)
             |> Ash.read(actor: context.actor, authorize?: false) do
          {:ok, contacts} ->
            formatted_contacts =
              Enum.map(contacts, fn contact ->
                %{
                  "name" =>
                    "#{contact.firstname || ""} #{contact.lastname || ""}" |> String.trim(),
                  "email" => contact.email,
                  "company" => contact.company,
                  "phone" => contact.phone,
                  "lifecycle_stage" => contact.lifecycle_stage,
                  "source" => contact.source,
                  "last_updated" =>
                    contact.external_updated_at &&
                      DateTime.to_iso8601(contact.external_updated_at)
                }
              end)

            {:ok, formatted_contacts}

          {:error, reason} ->
            {:error, "Failed to list contacts: #{inspect(reason)}"}
        end
      end
    end

    action :get_contact_by_id, :map do
      description """
      Gets a single contact by ID. Returns full contact details if found.
      """

      argument :contact_id, :uuid do
        allow_nil? false
        description "The ID of the contact to retrieve"
      end

      run fn input, context ->
        user_id = context.actor.id
        contact_id = input.arguments.contact_id

        case JumpstartAi.Accounts.Contact
             |> Ash.Query.for_read(:get_by_user, %{user_id: user_id})
             |> Ash.Query.filter(expr(id == ^contact_id))
             |> Ash.Query.select([
               :id,
               :firstname,
               :lastname,
               :email,
               :company,
               :phone,
               :lifecycle_stage,
               :source,
               :notes_summary,
               :external_updated_at
             ])
             |> Ash.read_one(actor: context.actor, authorize?: false) do
          {:ok, nil} ->
            {:error, "Contact not found"}

          {:ok, contact} ->
            formatted_contact = %{
              "id" => contact.id,
              "name" => "#{contact.firstname || ""} #{contact.lastname || ""}" |> String.trim(),
              "email" => contact.email,
              "company" => contact.company,
              "phone" => contact.phone,
              "lifecycle_stage" => contact.lifecycle_stage,
              "source" => contact.source,
              "notes_summary" => contact.notes_summary,
              "last_updated" =>
                contact.external_updated_at &&
                  DateTime.to_iso8601(contact.external_updated_at)
            }

            {:ok, formatted_contact}

          {:error, reason} ->
            {:error, "Failed to get contact: #{inspect(reason)}"}
        end
      end
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass action_type(:read) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:ash_ai_update_embeddings) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:vectorize) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:semantic_search_contacts) do
      authorize_if actor_present()
    end

    bypass action(:list_contacts) do
      authorize_if actor_present()
    end

    bypass action(:find_contact) do
      authorize_if actor_present()
    end

    bypass action(:search_contacts) do
      authorize_if actor_present()
    end

    bypass action(:search_for_mention) do
      authorize_if actor_present()
    end

    bypass action(:get_contact_by_id) do
      authorize_if actor_present()
    end

    bypass action(:create_from_hubspot) do
      authorize_if always()
    end

    bypass action(:create_from_google) do
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

  # Helper functions for unified search
  defp semantic_search(user_id, query, limit) do
    with {:ok, [search_vector]} <- JumpstartAi.OpenAiEmbeddingModel.generate([query], []) do
      semantic_sql = """
      SELECT id, firstname, lastname, email, company, phone, lifecycle_stage, source, notes_summary
      FROM contacts 
      WHERE user_id = $1 
        AND full_text_vector IS NOT NULL 
        AND (full_text_vector <=> $2) >= 0.7
      ORDER BY (full_text_vector <=> $2) DESC
      LIMIT $3
      """

      JumpstartAi.Repo.query(semantic_sql, [
        Ecto.UUID.dump!(user_id),
        search_vector,
        limit
      ])
      |> case do
        {:ok, %{rows: rows}} -> {:ok, rows}
        error -> error
      end
    end
  end

  defp format_contact_results(rows) do
    formatted_contacts =
      Enum.map(rows, fn [
                          id,
                          firstname,
                          lastname,
                          email,
                          company,
                          phone,
                          lifecycle_stage,
                          source,
                          notes_summary
                        ] ->
        %{
          "id" => Ecto.UUID.load!(id),
          "name" => "#{firstname || ""} #{lastname || ""}" |> String.trim(),
          "email" => email,
          "company" => company,
          "phone" => phone,
          "lifecycle_stage" => lifecycle_stage,
          "source" => source,
          "notes_summary" =>
            case notes_summary do
              nil -> nil
              text when byte_size(text) > 200 -> String.slice(text, 0, 200) <> "..."
              text -> text
            end
        }
      end)

    {:ok, formatted_contacts}
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
