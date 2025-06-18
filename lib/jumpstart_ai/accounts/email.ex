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

    strategy :manual
    embedding_model JumpstartAi.OpenAiEmbeddingModel
  end

  actions do
    defaults [:read]

    update :update do
      accept [:markdown_content]
      require_atomic? false

      # Trigger manual vectorization after update - only if vectorized fields changed
      change after_action(fn changeset, email, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :from_name,
                 :from_email,
                 :to_email,
                 :subject,
                 :date,
                 :snippet,
                 :markdown_content,
                 :body_text
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changed?(changeset, field)
                 end)

               if data_changed do
                 case email
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(actor: %AshAi{}, authorize?: false) do
                   {:ok, updated_email} ->
                     {:ok, updated_email}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for email #{email.id}: #{inspect(error)}"
                     )

                     {:ok, email}
                 end
               else
                 {:ok, email}
               end
             end)
    end

    update :vectorize do
      accept []
      change AshAi.Changes.Vectorize
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

    action :semantic_search_emails, {:array, :map} do
      description """
      Semantic search for emails using vector similarity. Searches email content, subject, and metadata for semantically similar content.
      """

      argument :query, :string do
        allow_nil? false
        description "The search query to find semantically similar emails"
      end

      argument :limit, :integer do
        allow_nil? true
        default 20
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
        limit = input.arguments.limit || 20
        similarity_threshold = input.arguments.similarity_threshold || 0.7

        # Generate embedding for the search query
        case JumpstartAi.OpenAiEmbeddingModel.generate([search_query], []) do
          {:ok, [search_vector]} ->
            # Use raw SQL for vector similarity search
            sql_query = """
            SELECT id, subject, from_email, from_name, date, snippet, body_text, markdown_content
            FROM emails
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
                formatted_emails =
                  Enum.map(rows, fn [
                                      id,
                                      subject,
                                      from_email,
                                      from_name,
                                      date,
                                      snippet,
                                      body_text,
                                      markdown_content
                                    ] ->
                    %{
                      "id" => Ecto.UUID.load!(id),
                      "subject" => subject || "No Subject",
                      "from_email" => from_email,
                      "from_name" => from_name,
                      "date" =>
                        date &&
                          if is_struct(date, DateTime) do
                            DateTime.to_iso8601(date)
                          else
                            NaiveDateTime.to_iso8601(date)
                          end,
                      "snippet" => snippet,
                      "content_preview" =>
                        case markdown_content || body_text do
                          nil -> snippet
                          text when byte_size(text) > 300 -> String.slice(text, 0, 300) <> "..."
                          text -> text
                        end
                    }
                  end)

                {:ok, formatted_emails}

              {:error, error} ->
                {:error, "Failed to search emails: #{inspect(error)}"}
            end

          {:error, error} ->
            {:error, "Failed to generate search embedding: #{inspect(error)}"}
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

    action :draft_email, :map do
      description """
      Drafts a new email and saves it to Gmail. Returns draft information.
      """

      argument :to, :string do
        allow_nil? false
        description "Recipient email address"
      end

      argument :subject, :string do
        allow_nil? false
        description "Email subject"
      end

      argument :body, :string do
        allow_nil? false
        description "Email body content"
      end

      argument :cc, :string do
        allow_nil? true
        description "CC recipients (comma-separated)"
      end

      argument :bcc, :string do
        allow_nil? true
        description "BCC recipients (comma-separated)"
      end

      run fn input, context ->
        user = context.actor

        email_params = %{
          to: input.arguments.to,
          subject: input.arguments.subject,
          body: input.arguments.body,
          cc: input.arguments[:cc],
          bcc: input.arguments[:bcc]
        }

        case JumpstartAi.GmailService.draft_email(user, email_params) do
          {:ok, draft_info} ->
            {:ok,
             %{
               "status" => "success",
               "message" => "Email drafted successfully",
               "draft_id" => draft_info.draft_id,
               "message_id" => draft_info.message_id,
               "thread_id" => draft_info.thread_id,
               "to" => input.arguments.to,
               "subject" => input.arguments.subject
             }}

          {:error, reason} ->
            {:error, "Failed to draft email: #{reason}"}
        end
      end
    end

    action :send_email, :map do
      description """
      Sends a new email through Gmail. Returns send confirmation.
      """

      argument :to, :string do
        allow_nil? false
        description "Recipient email address"
      end

      argument :subject, :string do
        allow_nil? false
        description "Email subject"
      end

      argument :body, :string do
        allow_nil? false
        description "Email body content"
      end

      argument :cc, :string do
        allow_nil? true
        description "CC recipients (comma-separated)"
      end

      argument :bcc, :string do
        allow_nil? true
        description "BCC recipients (comma-separated)"
      end

      run fn input, context ->
        user = context.actor

        email_params = %{
          to: input.arguments.to,
          subject: input.arguments.subject,
          body: input.arguments.body,
          cc: input.arguments[:cc],
          bcc: input.arguments[:bcc]
        }

        case JumpstartAi.GmailService.send_email(user, email_params) do
          {:ok, send_info} ->
            {:ok,
             %{
               "status" => "success",
               "message" => "Email sent successfully",
               "message_id" => send_info.message_id,
               "thread_id" => send_info.thread_id,
               "to" => input.arguments.to,
               "subject" => input.arguments.subject
             }}

          {:error, reason} ->
            {:error, "Failed to send email: #{reason}"}
        end
      end
    end

    action :list_drafts, {:array, :map} do
      description """
      Lists all draft emails from Gmail. Returns a list of drafts with their details.
      """

      argument :limit, :integer do
        allow_nil? true
        default 20
        description "Maximum number of drafts to return (default: 20)"
      end

      run fn input, context ->
        user = context.actor
        limit = input.arguments[:limit] || 20

        opts = if limit, do: [maxResults: limit], else: []

        case JumpstartAi.GmailService.list_drafts(user, opts) do
          {:ok, drafts} ->
            formatted_drafts =
              Enum.map(drafts, fn draft ->
                %{
                  "draft_id" => draft.draft_id,
                  "message_id" => draft.message_id,
                  "subject" => draft.subject || "No Subject",
                  "to" => draft.to,
                  "cc" => draft.cc,
                  "bcc" => draft.bcc,
                  "snippet" => draft.snippet,
                  "created_at" => draft.created_at
                }
              end)

            {:ok, formatted_drafts}

          {:error, reason} ->
            {:error, "Failed to list drafts: #{reason}"}
        end
      end
    end

    action :send_email_with_draft, :map do
      description """
      Sends an email using the content from an existing draft. Validates draft exists first.
      This is the SAFE way to send emails - requires a draft_id from a previously created draft.
      """

      argument :draft_id, :string do
        allow_nil? false
        description "The Gmail draft ID to extract content from and send"
      end

      run fn input, context ->
        user = context.actor
        draft_id = input.arguments.draft_id

        # First, get the draft to extract its content
        case JumpstartAi.GmailClient.get_draft(user, draft_id) do
          {:ok, draft_data} ->
            # Extract email details from the draft
            message = draft_data["message"]
            payload = message["payload"]
            headers = payload["headers"] || []

            # Get header values
            to = get_header_value(headers, "To")
            cc = get_header_value(headers, "Cc")
            bcc = get_header_value(headers, "Bcc")
            subject = get_header_value(headers, "Subject")

            # Extract body content
            body = extract_draft_body(payload)

            # Validate required fields
            if is_nil(to) or is_nil(subject) or is_nil(body) do
              {:error, "Draft is missing required fields (to, subject, or body)"}
            else
              # Send email using the regular send endpoint with draft content
              email_params = %{
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body
              }

              case JumpstartAi.GmailService.send_email(user, email_params) do
                {:ok, send_info} ->
                  {:ok,
                   %{
                     "status" => "success",
                     "message" => "Email sent successfully using draft content",
                     "message_id" => send_info.message_id,
                     "thread_id" => send_info.thread_id,
                     "draft_id" => draft_id,
                     "to" => to,
                     "subject" => subject
                   }}

                {:error, reason} ->
                  {:error, "Failed to send email: #{reason}"}
              end
            end

          {:error, reason} ->
            {:error, "Failed to get draft #{draft_id}: #{reason}"}
        end
      end
    end

    action :list_emails, {:array, :map} do
      description """
      Lists the latest emails for the user. Returns the 10 most recent emails with key details.
      """

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of emails to return (default: 10)"
      end

      run fn input, context ->
        user_id = context.actor.id
        limit = input.arguments[:limit] || 10

        case JumpstartAi.Accounts.Email
             |> Ash.Query.for_read(:read_user, %{user_id: user_id})
             |> Ash.Query.select([:subject, :from_email, :from_name, :to_email, :date, :snippet])
             |> Ash.Query.sort(date: :desc)
             |> Ash.Query.limit(limit)
             |> Ash.read(actor: context.actor, authorize?: false) do
          {:ok, emails} ->
            formatted_emails =
              Enum.map(emails, fn email ->
                %{
                  "subject" => email.subject || "No Subject",
                  "from_email" => email.from_email,
                  "from_name" => email.from_name,
                  "to_email" => email.to_email,
                  "date" => email.date && DateTime.to_iso8601(email.date),
                  "snippet" => email.snippet || "No preview available"
                }
              end)

            {:ok, formatted_emails}

          {:error, reason} ->
            {:error, "Failed to list emails: #{inspect(reason)}"}
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

    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action(:search_emails_by_from) do
      authorize_if actor_present()
    end

    bypass action(:vectorize) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:semantic_search_emails) do
      authorize_if actor_present()
    end

    policy action(:draft_email) do
      authorize_if actor_present()
    end

    policy action(:send_email) do
      authorize_if actor_present()
    end

    policy action(:list_drafts) do
      authorize_if actor_present()
    end

    policy action(:send_email_with_draft) do
      authorize_if actor_present()
    end

    policy action(:list_emails) do
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

  # Helper function to get header value from Gmail API response
  defp get_header_value(headers, name) do
    case Enum.find(headers, fn header -> header["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  # Helper function to extract body content from draft payload
  defp extract_draft_body(payload) do
    cond do
      payload["body"] && payload["body"]["data"] ->
        # Single part message
        decode_base64(payload["body"]["data"])

      payload["parts"] ->
        # Multi-part message - find text/plain part
        find_text_body_in_parts(payload["parts"])

      true ->
        nil
    end
  end

  defp find_text_body_in_parts(parts) do
    parts
    |> Enum.find(fn part -> part["mimeType"] == "text/plain" end)
    |> case do
      %{"body" => %{"data" => data}} -> decode_base64(data)
      %{"parts" => nested_parts} -> find_text_body_in_parts(nested_parts)
      _ -> nil
    end
  end

  defp decode_base64(data) when is_binary(data) do
    try do
      # Gmail uses URL-safe base64 with padding removed
      # Convert URL-safe characters back to standard base64
      data
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      # Add padding if needed
      |> pad_base64()
      |> Base.decode64!()
    rescue
      _ -> nil
    end
  end

  defp decode_base64(_), do: nil

  defp pad_base64(data) do
    # Add padding to make the string length a multiple of 4
    case rem(String.length(data), 4) do
      0 -> data
      1 -> data <> "==="
      2 -> data <> "=="
      3 -> data <> "="
    end
  end
end
