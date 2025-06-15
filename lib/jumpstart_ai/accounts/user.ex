defmodule JumpstartAi.Accounts.User do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshOban]

  authentication do
    add_ons do
      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        sender JumpstartAi.Accounts.User.Senders.SendNewUserConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource JumpstartAi.Accounts.Token
      signing_secret JumpstartAi.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      google do
        client_id JumpstartAi.Secrets
        redirect_uri JumpstartAi.Secrets
        client_secret JumpstartAi.Secrets

        authorization_params access_type: "offline",
                             prompt: "consent",
                             scope:
                               "https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/gmail.readonly"
      end

      oauth2 :hubspot do
        client_id JumpstartAi.Secrets
        client_secret JumpstartAi.Secrets
        redirect_uri JumpstartAi.Secrets
        base_url "https://api.hubapi.com"
        authorize_url "https://app-na2.hubspot.com/oauth/authorize"
        token_url "https://api.hubapi.com/oauth/v1/token"
        user_url "https://api.hubapi.com/oauth/v1/access-tokens/{token}"

        authorization_params scope:
                               "crm.objects.contacts.write timeline sales-email-read oauth crm.objects.contacts.read"
      end
    end
  end

  postgres do
    table "users"
    repo JumpstartAi.Repo
  end

  actions do
    defaults [:read]

    read :get_by_id do
      description "Fetch a single user by UUID"
      get? true

      argument :id, :uuid, allow_nil?: false

      filter expr(id == ^arg(:id))
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get? true

      argument :email, :ci_string do
        allow_nil? false
      end

      filter expr(email == ^arg(:email))
    end

    create :register_with_google do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_email

      change AshAuthentication.GenerateTokenChange

      # Required if you have the `identity_resource` configuration enabled.
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      change fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)
        oauth_tokens = Ash.Changeset.get_argument(changeset, :oauth_tokens)

        expires_at =
          case oauth_tokens["expires_in"] do
            expires_in when is_integer(expires_in) ->
              DateTime.utc_now() |> DateTime.add(expires_in, :second)

            _ ->
              nil
          end

        changeset
        |> Ash.Changeset.change_attributes(Map.take(user_info, ["email"]))
        |> Ash.Changeset.change_attribute(:google_access_token, oauth_tokens["access_token"])
        |> Ash.Changeset.change_attribute(:google_refresh_token, oauth_tokens["refresh_token"])
        |> Ash.Changeset.change_attribute(:google_token_expires_at, expires_at)
      end

      # Required if you're using the password & confirmation strategies
      upsert_fields []
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
      change set_attribute(:email_sync_status, "pending")

      change after_action(fn _changeset, user, _context ->
               case user.confirmed_at do
                 nil ->
                   {:error, "Unconfirmed user exists already"}

                 _ ->
                   # Trigger email sync for Google OAuth users
                   if not is_nil(user.google_access_token) and
                        (is_nil(user.emails_synced_at) or user.email_sync_status == "pending") do
                     # Schedule job with a longer delay for new users to ensure tokens are properly set
                     # The EmailSync worker will handle cases where refresh token is missing
                     JumpstartAi.Workers.EmailSync.new(%{user_id: user.id})
                     |> Oban.insert(schedule_in: 10)
                   end

                   {:ok, user}
               end
             end)
    end

    create :register_with_hubspot do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_email

      change AshAuthentication.GenerateTokenChange

      # Required if you have the `identity_resource` configuration enabled.
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      change fn changeset, _ ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)
        oauth_tokens = Ash.Changeset.get_argument(changeset, :oauth_tokens)

        expires_at =
          case oauth_tokens["expires_in"] do
            expires_in when is_integer(expires_in) ->
              DateTime.utc_now() |> DateTime.add(expires_in, :second)

            _ ->
              nil
          end

        # Extract portal_id from HubSpot user info or token response
        portal_id = user_info["hub_id"] || oauth_tokens["hub_id"]

        changeset
        |> Ash.Changeset.change_attributes(Map.take(user_info, ["email"]))
        |> Ash.Changeset.change_attribute(:hubspot_access_token, oauth_tokens["access_token"])
        |> Ash.Changeset.change_attribute(:hubspot_refresh_token, oauth_tokens["refresh_token"])
        |> Ash.Changeset.change_attribute(:hubspot_token_expires_at, expires_at)
        |> Ash.Changeset.change_attribute(:hubspot_portal_id, portal_id)
      end

      # Required if you're using the password & confirmation strategies
      upsert_fields []
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :update do
      description "Update user attributes including Google and HubSpot tokens"

      accept [
        :google_access_token,
        :google_token_expires_at,
        :email_sync_status,
        :hubspot_access_token,
        :hubspot_refresh_token,
        :hubspot_token_expires_at,
        :hubspot_portal_id
      ]
    end

    update :update_hubspot_tokens do
      description "Update HubSpot API tokens for a user"
      require_atomic? false

      accept [
        :hubspot_access_token,
        :hubspot_refresh_token,
        :hubspot_token_expires_at,
        :hubspot_portal_id
      ]

      argument :access_token, :string, allow_nil?: false
      argument :refresh_token, :string, allow_nil?: true
      argument :expires_in, :integer, allow_nil?: true
      argument :portal_id, :string, allow_nil?: true

      change fn changeset, _context ->
        access_token = Ash.Changeset.get_argument(changeset, :access_token)
        refresh_token = Ash.Changeset.get_argument(changeset, :refresh_token)
        expires_in = Ash.Changeset.get_argument(changeset, :expires_in)
        portal_id = Ash.Changeset.get_argument(changeset, :portal_id)

        expires_at =
          case expires_in do
            expires_in when is_integer(expires_in) ->
              DateTime.utc_now() |> DateTime.add(expires_in, :second)

            _ ->
              nil
          end

        changeset
        |> Ash.Changeset.change_attribute(:hubspot_access_token, access_token)
        |> Ash.Changeset.change_attribute(:hubspot_refresh_token, refresh_token)
        |> Ash.Changeset.change_attribute(:hubspot_token_expires_at, expires_at)
        |> Ash.Changeset.change_attribute(:hubspot_portal_id, portal_id)
      end
    end

    update :sync_gmail_emails do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        user = changeset.data

        # Check if user has Google access token
        if is_nil(user.google_access_token) do
          changeset
          |> Ash.Changeset.change_attribute(:email_sync_status, "failed")
          |> Ash.Changeset.add_error(
            field: :email_sync_status,
            message: "No Google access token available"
          )
        else
          # Set to processing to indicate work is starting
          changeset = Ash.Changeset.change_attribute(changeset, :email_sync_status, "processing")

          case JumpstartAi.GmailService.fetch_user_emails(user, maxResults: 10) do
            {:ok, emails} ->
              Enum.each(emails, fn email_data ->
                JumpstartAi.Accounts.Email
                |> Ash.Changeset.new()
                |> Ash.Changeset.set_argument(:user_id, user.id)
                |> Ash.Changeset.for_create(
                  :create_from_gmail,
                  %{
                    gmail_id: email_data.id,
                    thread_id: email_data.thread_id,
                    subject: email_data.subject,
                    from_email: extract_email_from_string(email_data.from),
                    from_name: extract_name_from_string(email_data.from),
                    to_email: extract_email_from_string(email_data.to),
                    date: parse_email_date(email_data.date),
                    snippet: email_data.snippet,
                    body_text: email_data.body_text,
                    body_html: email_data.body_html,
                    label_ids: email_data.label_ids,
                    attachments: email_data.attachments || [],
                    mime_type: email_data.mime_type
                  },
                  actor: user,
                  authorize?: false
                )
                |> Ash.create()
              end)

              changeset
              |> Ash.Changeset.change_attribute(:email_sync_status, "completed")
              |> Ash.Changeset.change_attribute(:emails_synced_at, DateTime.utc_now())

            {:error, reason} ->
              changeset
              |> Ash.Changeset.change_attribute(:email_sync_status, "failed")
              |> Ash.Changeset.add_error(
                field: :email_sync_status,
                message: "Failed to sync emails: #{inspect(reason)}"
              )
          end
        end
      end
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

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :confirmed_at, :utc_datetime_usec

    attribute :google_access_token, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :google_refresh_token, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :google_token_expires_at, :utc_datetime_usec do
      allow_nil? true
    end

    attribute :email_sync_status, :string do
      allow_nil? true
    end

    attribute :emails_synced_at, :utc_datetime_usec do
      allow_nil? true
    end

    attribute :hubspot_access_token, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :hubspot_refresh_token, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :hubspot_token_expires_at, :utc_datetime_usec do
      allow_nil? true
    end

    attribute :hubspot_portal_id, :string do
      allow_nil? true
    end
  end

  relationships do
    has_many :emails, JumpstartAi.Accounts.Email do
      public? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  defp extract_email_from_string(nil), do: nil

  defp extract_email_from_string(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] ->
        email

      _ ->
        case Regex.run(~r/([^\s<>]+@[^\s<>]+)/, email_string) do
          [_, email] -> email
          _ -> email_string
        end
    end
  end

  defp extract_name_from_string(nil), do: nil

  defp extract_name_from_string(email_string) when is_binary(email_string) do
    case Regex.run(~r/^([^<]+)</, email_string) do
      [_, name] -> String.trim(name, ~s("))
      _ -> nil
    end
  end

  defp parse_email_date(nil), do: nil

  defp parse_email_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} ->
        datetime

      _ ->
        try do
          case Timex.parse(date_string, "{RFC1123}") do
            {:ok, datetime} -> datetime
            _ -> nil
          end
        rescue
          _ -> nil
        end
    end
  end
end
