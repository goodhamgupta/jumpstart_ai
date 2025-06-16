defmodule JumpstartAi.Accounts.ContactNote do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi]
    
  alias JumpstartAi.TextUtils

  postgres do
    table "contact_notes"
    repo JumpstartAi.Repo
  end

  vectorize do
    # Combine note metadata and content for semantic search
    full_text do
      text fn note ->
        metadata = """
        Note Type: #{note.note_type || "NOTE"}
        Source: #{note.source || "Unknown"}
        Created: #{if note.external_created_at, do: Calendar.strftime(note.external_created_at, "%Y-%m-%d %H:%M"), else: "Unknown"}
        """
        
        content = TextUtils.clean_and_truncate(note.content || "", 6000)
        
        metadata <> "\n\nContent:\n" <> content
      end
      
      used_attributes [
        :note_type,
        :source,
        :content,
        :external_created_at
      ]
    end
    
    strategy :manual
    embedding_model JumpstartAi.OpenAiEmbeddingModel
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
      
      # Automatic vectorization after contact note creation/update
      change after_action(fn _changeset, note, _context ->
               case note
                    |> Ash.Changeset.for_update(:vectorize, %{})
                    |> Ash.update(actor: %AshAi{}, authorize?: false) do
                 {:ok, updated_note} ->
                   {:ok, updated_note}
                 
                 {:error, error} ->
                   require Logger
                   
                   Logger.warning(
                     "Failed to update embeddings for contact note #{note.id} from HubSpot: #{inspect(error)}"
                   )
                   
                   {:ok, note}
               end
             end)

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
      require_atomic? false
      
      # Trigger manual vectorization after update
      change after_action(fn _changeset, note, _context ->
               case note
                    |> Ash.Changeset.for_update(:vectorize, %{})
                    |> Ash.update(actor: %AshAi{}, authorize?: false) do
                 {:ok, updated_note} ->
                   {:ok, updated_note}
                 
                 {:error, error} ->
                   require Logger
                   
                   Logger.warning(
                     "Failed to update embeddings for contact note #{note.id}: #{inspect(error)}"
                   )
                   
                   {:ok, note}
               end
             end)
    end
    
    update :vectorize do
      accept []
      change AshAi.Changes.Vectorize
      require_atomic? false
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
    
    action :generate_note_summary, :string do
      description """
      Generates a concise summary of the contact note content using LLM.
      """
      
      argument :content, :string do
        allow_nil? false
        description "Note content to summarize"
      end
      
      argument :note_type, :string do
        allow_nil? true
        description "Type of note for context"
      end
      
      run prompt(
            fn _input, _context ->
              LangChain.ChatModels.ChatOpenAI.new!(%{
                model: "gpt-4.1-mini-2025-04-14",
                api_key: System.get_env("OPENAI_API_KEY"),
                timeout: 30_000,
                temperature: 0,
                max_tokens: 500
              })
            end,
            tools: false,
            prompt: """
            Summarize this contact note in 1-2 sentences. Focus on key insights, decisions, or action items.
            
            Note Type: <%= @input.arguments.note_type || "General" %>
            
            Content:
            <%= @input.arguments.content %>
            """
          )
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
    
    policy action(:vectorize) do
      authorize_if AshAi.Checks.ActorIsAshAi
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
