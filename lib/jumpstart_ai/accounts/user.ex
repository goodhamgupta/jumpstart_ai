defmodule JumpstartAi.Accounts.User do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshOban]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        auto_confirm_actions [:sign_in_with_magic_link, :reset_password_with_token]
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
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider

        resettable do
          sender JumpstartAi.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      google do
        client_id JumpstartAi.Secrets
        redirect_uri JumpstartAi.Secrets
        client_secret JumpstartAi.Secrets
      end
    end
  end

  postgres do
    table "users"
    repo JumpstartAi.Repo
  end

  oban do
    triggers do
      trigger :sync_emails do
        action :sync_gmail_emails
        where expr(not is_nil(google_access_token))
        worker_read_action :read
        worker_module_name JumpstartAi.Workers.EmailSync
        max_attempts 3
        queue :email_sync
        scheduler_module_name JumpstartAi.Accounts.User.AshOban.Scheduler.SyncEmails
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      # Use this action to allow users to change their password by providing
      # their current password and a new password.

      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # validates the provided email and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      # trigger email sync for users who haven't synced emails yet
      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, user, _context ->
          if not is_nil(user.google_access_token) and
               (is_nil(user.emails_synced_at) or user.email_sync_status == "pending") do
            AshOban.run_trigger(user, :sync_emails)
          end

          {:ok, user}
        end)
      end

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      # In the generated sign in components, we validate the
      # email and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      # trigger email sync for users who haven't synced emails yet
      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, user, _context ->
          if not is_nil(user.google_access_token) and
               (is_nil(user.emails_synced_at) or user.email_sync_status == "pending") do
            AshOban.run_trigger(user, :sync_emails)
          end

          {:ok, user}
        end)
      end

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Sets the email from the argument
      change set_attribute(:email, arg(:email))

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get? true

      argument :email, :ci_string do
        allow_nil? false
      end

      filter expr(email == ^arg(:email))
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
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
                     AshOban.run_trigger(user, :sync_emails)
                   end

                   {:ok, user}
               end
             end)
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
                    body_text: email_data.body,
                    label_ids: email_data.label_ids
                  },
                  actor: user
                )
                |> Ash.Changeset.set_argument(:user_id, user.id)
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

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
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
