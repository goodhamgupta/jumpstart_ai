defmodule JumpstartAi.Accounts.Email do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAi]

  postgres do
    table "emails"
    repo JumpstartAi.Repo
  end

  vectorize do
    # Combine metadata and content into a single vector for semantic search
    full_text do
      text fn email ->
        # Clean and format metadata
        metadata = """
        From: #{clean_text(email.from_name || "Unknown")} <#{email.from_email || "unknown@example.com"}>
        To: #{email.to_email || "unknown@example.com"}
        Subject: #{clean_text(email.subject || "No Subject")}
        Date: #{if email.date, do: Calendar.strftime(email.date, "%Y-%m-%d %H:%M"), else: "Unknown"}
        Snippet: #{clean_text(email.snippet || "No snippet")}
        """

        content = email.markdown_content || email.body_text || ""
        # Clean and truncate content
        content =
          content
          |> clean_text()

          # Leave room for metadata

          |> truncate_for_embedding(6000)

        metadata <> "\n\nContent:\n" <> content
      end

      used_attributes [
        :from_name,
        :from_email,
        :to_email,
        :subject,
        :date,
        :snippet,
        :markdown_content,
        :body_text
      ]
    end

    strategy :after_action
    embedding_model JumpstartAi.OpenAiEmbeddingModel
  end

  actions do
    defaults [:read]

    update :update do
      accept [:markdown_content]
      require_atomic? false
    end

    read :read_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :search_emails do
      description "Search emails by subject, from, to, or body content"
      argument :query, :string, allow_nil?: false

      filter expr(
               ilike(subject, ^arg(:query)) or
                 ilike(from_email, ^arg(:query)) or
                 ilike(from_name, ^arg(:query)) or
                 ilike(to_email, ^arg(:query)) or
                 ilike(body_text, ^arg(:query)) or
                 ilike(snippet, ^arg(:query))
             )
    end

    read :search_by_from_email do
      description "Search emails by from_email field"
      argument :from_email, :string, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 ilike(from_email, ^arg(:from_email))
             )
    end

    action :search_emails_by_from, {:array, :map} do
      description """
      Search for emails by from_email field. Returns a list of emails from the specified sender.
      """

      argument :from_email, :string do
        allow_nil? false
        description "The email address to search for in the from_email field"
      end

      run fn input, context ->
        user_id = context.actor.id
        from_email = input.arguments.from_email

        case JumpstartAi.Accounts.Email
             |> Ash.Query.for_read(:search_by_from_email, %{
               from_email: "%#{from_email}%",
               user_id: user_id
             })
             |> Ash.Query.select([:subject, :from_email, :from_name, :date, :snippet, :body_text])
             |> Ash.Query.sort(date: :desc)
             |> Ash.Query.limit(20)
             |> Ash.read(actor: context.actor, authorize?: false) do
          {:ok, emails} ->
            formatted_emails =
              Enum.map(emails, fn email ->
                %{
                  "subject" => email.subject || "No Subject",
                  "from_email" => email.from_email,
                  "from_name" => email.from_name,
                  "date" => email.date && DateTime.to_iso8601(email.date),
                  "snippet" => email.snippet,
                  "body_preview" =>
                    case email.body_text do
                      nil -> nil
                      text when byte_size(text) > 200 -> String.slice(text, 0, 200) <> "..."
                      text -> text
                    end
                }
              end)

            {:ok, formatted_emails}

          {:error, error} ->
            {:error, "Failed to search emails: #{inspect(error)}"}
        end
      end
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
        :attachments,
        :mime_type,
        :user_id,
        :markdown_content
      ]

      argument :user_id, :uuid, allow_nil?: false
      change set_attribute(:user_id, arg(:user_id))

      # Queue markdown generation after email creation/update
      change after_action(fn _changeset, email, _context ->
               # Only queue markdown generation if email doesn't already have markdown content
               # and has content to process
               if should_generate_markdown?(email) do
                 case JumpstartAi.Workers.EmailMarkdownWorker.enqueue_single_email(email.id) do
                   {:ok, _job} ->
                     {:ok, email}

                   {:error, error} ->
                     # Don't fail email creation if markdown job fails to enqueue
                     require Logger

                     Logger.warning(
                       "Failed to enqueue markdown generation for email #{email.id}: #{inspect(error)}"
                     )

                     {:ok, email}
                 end
               else
                 {:ok, email}
               end
             end)

      upsert? true
      upsert_identity :unique_gmail_id_per_user
    end

    action :generate_markdown_content, :string do
      description """
      Converts email content to clean, readable markdown format using LLM.
      Prioritizes body_text, then body_html, then snippet for content source.
      """

      argument :body_text, :string do
        allow_nil? true
        description "Plain text body content"
      end

      argument :body_html, :string do
        allow_nil? true
        description "HTML body content"
      end

      argument :snippet, :string do
        allow_nil? true
        description "Email snippet/preview"
      end

      argument :subject, :string do
        allow_nil? true
        description "Email subject for context"
      end

      run prompt(
            fn _input, _context ->
              LangChain.ChatModels.ChatOpenAI.new!(%{
                model: "gpt-4.1-mini-2025-04-14",
                api_key: System.get_env("OPENAI_API_KEY"),
                timeout: 30_000,
                temperature: 0,
                max_tokens: 4000
              })
            end,
            tools: false,
            prompt: """
            Convert to clean markdown. Remove HTML tags, signatures, footers. Keep core message only.

            Subject: <%= @input.arguments.subject || "No subject" %>

            <%= cond do %>
              <% @input.arguments.body_text && String.trim(@input.arguments.body_text) != "" -> %>
                <%= @input.arguments.body_text %>
              <% @input.arguments.body_html && String.trim(@input.arguments.body_html) != "" -> %>
                <%= @input.arguments.body_html %>
              <% @input.arguments.snippet && String.trim(@input.arguments.snippet) != "" -> %>
                <%= @input.arguments.snippet %>
              <% true -> %>
                [No content available]
            <% end %>
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

    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action(:search_emails_by_from) do
      authorize_if actor_present()
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

    attribute :attachments, {:array, :map} do
      allow_nil? true
      public? true
      default []
    end

    attribute :mime_type, :string do
      allow_nil? true
      public? true
    end

    attribute :markdown_content, :string do
      allow_nil? true
      public? true
      description "LLM-generated markdown content from email body"
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

  # Helper function to determine if markdown generation is needed
  defp should_generate_markdown?(email) do
    # Generate markdown if:
    # 1. Email doesn't already have markdown content
    # 2. Email has at least one content source (body_text, body_html, or snippet)
    is_nil(email.markdown_content) and has_content?(email)
  end

  defp has_content?(email) do
    has_body_text = email.body_text && String.trim(email.body_text) != ""
    has_body_html = email.body_html && String.trim(email.body_html) != ""
    has_snippet = email.snippet && String.trim(email.snippet) != ""

    !!has_body_text or !!has_body_html or !!has_snippet
  end

  # Helper function to truncate content for embeddings
  defp truncate_for_embedding(content, max_tokens) when is_binary(content) do
    # Rough estimate: 1 token ≈ 4 characters for English text
    max_chars = max_tokens * 4

    if String.length(content) > max_chars do
      content
      |> String.slice(0, max_chars)
      |> String.reverse()
      |> String.split(" ", parts: 2)
      |> List.last()
      |> String.reverse()
      |> then(&(&1 <> "..."))
    else
      content
    end
  end

  defp truncate_for_embedding(nil, _max_tokens), do: ""

  # Helper function to clean text for embeddings
  defp clean_text(text) when is_binary(text) do
    text
    # Remove HTML entities like &#39;
    |> String.replace(~r/&#\d+;/, " ")
    # Remove named HTML entities like &amp;
    |> String.replace(~r/&[a-zA-Z]+;/, " ")
    # Remove all non-ASCII characters
    |> String.replace(~r/[^\x00-\x7F]/, " ")
    # Normalize all whitespace to single spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_text(nil), do: ""
end
