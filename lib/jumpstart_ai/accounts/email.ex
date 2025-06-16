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
