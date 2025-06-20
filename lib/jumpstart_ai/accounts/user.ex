defmodule JumpstartAi.Accounts.User do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshOban]

  require Logger

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
                               "https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.app.created https://www.googleapis.com/auth/calendar.events.owned"
      end

      oauth2 :hubspot do
        client_id JumpstartAi.Secrets
        client_secret JumpstartAi.Secrets
        redirect_uri JumpstartAi.Secrets
        base_url "https://api.hubapi.com"
        authorize_url "https://app.hubspot.com/oauth/authorize"
        token_url "https://api.hubapi.com/oauth/v1/token"
        user_url "https://api.hubapi.com/crm/v3/owners"
        register_action_name :register_with_hubspot

        authorization_params scope:
                               "crm.objects.contacts.write timeline sales-email-read oauth crm.objects.contacts.read crm.objects.owners.read"
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

      change after_action(fn _changeset, user, _context ->
               case user.confirmed_at do
                 nil ->
                   {:error, "Unconfirmed user exists already"}

                 _ ->
                   # Trigger email sync for Google OAuth users
                   if not is_nil(user.google_access_token) and is_nil(user.emails_synced_at) do
                     # Schedule job with a longer delay for new users to ensure tokens are properly set
                     # The EmailSync worker will handle cases where refresh token is missing
                     JumpstartAi.Workers.EmailSync.new(%{user_id: user.id})
                     |> Oban.insert(schedule_in: 10)
                   end

                   # Trigger contact sync for Google OAuth users
                   if not is_nil(user.google_access_token) and is_nil(user.contacts_synced_at) do
                     # Schedule contact sync job
                     JumpstartAi.Workers.ContactSync.new(%{user_id: user.id})
                     |> Oban.insert(schedule_in: 15)
                   end

                   # Trigger calendar sync for Google OAuth users
                   if not is_nil(user.google_access_token) and is_nil(user.calendar_synced_at) do
                     # Schedule calendar sync job
                     JumpstartAi.Workers.CalendarSync.new(%{user_id: user.id})
                     |> Oban.insert(schedule_in: 20)
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

      # Make email optional for HubSpot since we're mainly updating existing users
      accept [:email]

      change AshAuthentication.GenerateTokenChange

      # Required if you have the `identity_resource` configuration enabled.
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      change fn changeset, context ->
        # Add detailed logging to debug OAuth flow
        require Logger
        Logger.info("=== HubSpot OAuth Action Called ===")
        Logger.info("HubSpot OAuth - Changeset data: #{inspect(changeset.data)}")
        Logger.info("HubSpot OAuth - Changeset attributes: #{inspect(changeset.attributes)}")
        Logger.info("HubSpot OAuth - Changeset arguments: #{inspect(changeset.arguments)}")
        Logger.info("HubSpot OAuth - Context: #{inspect(context)}")

        user_info = Ash.Changeset.get_argument(changeset, :user_info)
        oauth_tokens = Ash.Changeset.get_argument(changeset, :oauth_tokens)

        Logger.info("HubSpot OAuth - User Info: #{inspect(user_info)}")
        Logger.info("HubSpot OAuth - OAuth Tokens: #{inspect(oauth_tokens)}")

        # For HubSpot OAuth, we need to ensure we have an email for the upsert to work
        # Get the current user from context if available (they should be logged in)
        current_user_email =
          case context do
            %{actor: %{email: email}} when not is_nil(email) -> email
            _ -> nil
          end

        Logger.info(
          "HubSpot OAuth - Current user email from context: #{inspect(current_user_email)}"
        )

        # Ensure we have oauth_tokens
        case oauth_tokens do
          nil ->
            Logger.error("HubSpot OAuth - No oauth_tokens provided!")
            changeset

          %{} = tokens ->
            Logger.info("HubSpot OAuth - Processing tokens: #{inspect(Map.keys(tokens))}")

            expires_at =
              case tokens["expires_in"] do
                expires_in when is_integer(expires_in) ->
                  DateTime.utc_now() |> DateTime.add(expires_in, :second)

                _ ->
                  nil
              end

            # Determine the email to use - HubSpot returns user info in results array
            email_from_user_info =
              case user_info do
                %{"results" => [%{"email" => email} | _]} when not is_nil(email) -> email
                %{"email" => email} when not is_nil(email) -> email
                %{"user" => email} when not is_nil(email) -> email
                _ -> nil
              end

            email_to_use = current_user_email || changeset.data.email || email_from_user_info

            Logger.info("HubSpot OAuth - Email to use: #{inspect(email_to_use)}")

            Logger.info(
              "HubSpot OAuth - Access token present: #{not is_nil(tokens["access_token"])}"
            )

            Logger.info(
              "HubSpot OAuth - Refresh token present: #{not is_nil(tokens["refresh_token"])}"
            )

            Logger.info("HubSpot OAuth - Expires at: #{inspect(expires_at)}")

            # Extract HubSpot user ID from user info if available
            hubspot_user_id =
              case user_info do
                %{"results" => [%{"userId" => user_id} | _]} when not is_nil(user_id) ->
                  to_string(user_id)

                _ ->
                  nil
              end

            Logger.info("HubSpot OAuth - HubSpot User ID: #{inspect(hubspot_user_id)}")

            # Always set the email for upsert to work properly
            final_changeset =
              changeset
              |> Ash.Changeset.change_attribute(:email, email_to_use)
              |> Ash.Changeset.change_attribute(:hubspot_access_token, tokens["access_token"])
              |> Ash.Changeset.change_attribute(:hubspot_refresh_token, tokens["refresh_token"])
              |> Ash.Changeset.change_attribute(:hubspot_token_expires_at, expires_at)
              |> then(fn cs ->
                if hubspot_user_id,
                  do: Ash.Changeset.change_attribute(cs, :hubspot_portal_id, hubspot_user_id),
                  else: cs
              end)

            Logger.info(
              "HubSpot OAuth - Final changeset attributes: #{inspect(final_changeset.attributes)}"
            )

            final_changeset

          _ ->
            Logger.error("HubSpot OAuth - Invalid oauth_tokens format: #{inspect(oauth_tokens)}")
            changeset
        end
      end

      # Required if you're using the password & confirmation strategies
      upsert_fields [
        :hubspot_access_token,
        :hubspot_refresh_token,
        :hubspot_token_expires_at,
        :hubspot_portal_id
      ]

      change set_attribute(:confirmed_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, user, _context ->
               # Schedule HubSpot contact sync for newly connected users
               Logger.info("HubSpot OAuth - Scheduling sync for user #{user.id}")
               Logger.info("HubSpot OAuth - User email: #{user.email}")

               Logger.info(
                 "HubSpot OAuth - Has HubSpot token: #{not is_nil(user.hubspot_access_token)}"
               )

               if not is_nil(user.hubspot_access_token) do
                 case JumpstartAi.Workers.HubSpotSync.schedule_sync(user.id, "contacts", 10) do
                   {:ok, job} ->
                     Logger.info(
                       "HubSpot OAuth - Successfully scheduled sync job: #{inspect(job.id)}"
                     )

                   {:error, error} ->
                     Logger.error(
                       "HubSpot OAuth - Failed to schedule sync job: #{inspect(error)}"
                     )
                 end
               else
                 Logger.warning(
                   "HubSpot OAuth - No HubSpot access token, skipping sync scheduling"
                 )
               end

               {:ok, user}
             end)
    end

    update :update do
      description "Update user attributes including Google and HubSpot tokens"

      accept [
        :google_access_token,
        :google_token_expires_at,
        :hubspot_access_token,
        :hubspot_refresh_token,
        :hubspot_token_expires_at,
        :hubspot_portal_id,
        :emails_synced_at,
        :contacts_synced_at,
        :calendar_synced_at
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

    update :system_update_tokens do
      description "System update for token refresh - bypasses authentication policies"
      require_atomic? false

      accept [
        :hubspot_access_token,
        :hubspot_refresh_token,
        :hubspot_token_expires_at,
        :hubspot_portal_id
      ]
    end

    update :sync_gmail_emails do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        user = changeset.data

        # Check if user has Google access token
        if is_nil(user.google_access_token) do
          changeset
          |> Ash.Changeset.add_error(
            field: :google_access_token,
            message: "No Google access token available"
          )
        else
          # Define the process function that will be called for each batch of emails
          process_batch_fn = fn emails ->
            # Convert email data to the format expected by the Email resource
            email_inputs =
              Enum.map(emails, fn email_data ->
                %{
                  user_id: user.id,
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
                }
              end)

            # Process emails in smaller chunks of 10 for database insertion
            email_inputs
            |> Enum.chunk_every(10)
            |> Enum.each(fn chunk ->
              Ash.bulk_create(
                chunk,
                JumpstartAi.Accounts.Email,
                :create_from_gmail,
                upsert?: true,
                upsert_identity: :unique_gmail_id_per_user,
                upsert_fields: [
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
                  :mime_type
                ],
                actor: user,
                authorize?: false,
                return_records?: false,
                stop_on_error?: false
              )
            end)

            {:ok, length(email_inputs)}
          end

          # Use streaming approach to process emails in batches
          case JumpstartAi.GmailService.stream_user_emails(user,
                 batch_size: 50,
                 max_results: 100,
                 process_fn: process_batch_fn
               ) do
            {:ok, total_processed} ->
              updated_changeset =
                changeset
                |> Ash.Changeset.change_attribute(:emails_synced_at, DateTime.utc_now())

              updated_changeset

            {:error, reason} ->
              changeset
              |> Ash.Changeset.add_error(
                field: :emails_synced_at,
                message: "Failed to sync emails: #{inspect(reason)}"
              )
          end
        end
      end
    end

    update :sync_google_contacts do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        user = changeset.data

        # Check if user has Google access token
        if is_nil(user.google_access_token) do
          changeset
          |> Ash.Changeset.add_error(
            field: :google_access_token,
            message: "No Google access token available"
          )
        else
          # Define the process function that will be called for each batch of contacts
          process_batch_fn = fn contacts ->
            # Convert contact data to the format expected by the Contact resource
            contact_inputs =
              Enum.map(contacts, fn contact_data ->
                %{
                  google_data: contact_data,
                  user_id: user.id
                }
              end)

            # Process contacts in smaller chunks of 10 for database insertion
            contact_inputs
            |> Enum.chunk_every(10)
            |> Enum.each(fn chunk ->
              Ash.bulk_create(
                chunk,
                JumpstartAi.Accounts.Contact,
                :create_from_google,
                upsert?: true,
                upsert_identity: :unique_external_contact,
                upsert_fields: [
                  :email,
                  :firstname,
                  :lastname,
                  :phone,
                  :company,
                  :notes_summary,
                  :external_updated_at
                ],
                actor: user,
                authorize?: false,
                return_records?: false,
                stop_on_error?: false
              )
            end)

            {:ok, length(contact_inputs)}
          end

          # Use streaming approach to process contacts in batches
          case JumpstartAi.GoogleContactsService.stream_user_contacts(user,
                 # Fetch 50 contacts at a time from Google API
                 batch_size: 5,
                 max_results: 50,
                 process_fn: process_batch_fn
               ) do
            {:ok, total_processed} ->
              changeset
              |> Ash.Changeset.change_attribute(:contacts_synced_at, DateTime.utc_now())

            {:error, reason} ->
              changeset
              |> Ash.Changeset.add_error(
                field: :contacts_synced_at,
                message: "Failed to sync contacts: #{inspect(reason)}"
              )
          end
        end
      end
    end

    update :sync_hubspot_contacts do
      description "Sync HubSpot contacts for a user"
      require_atomic? false
      accept []

      change after_action(fn _changeset, user, _context ->
               if not is_nil(user.hubspot_access_token) do
                 # Schedule HubSpot sync job
                 JumpstartAi.Workers.HubSpotSync.schedule_sync(user.id, "contacts", 5)
               end

               {:ok, user}
             end)
    end

    update :sync_calendar_events do
      require_atomic? false
      accept []

      change fn changeset, _context ->
        user = changeset.data

        # Check if user has Google access token
        if is_nil(user.google_access_token) do
          changeset
          |> Ash.Changeset.add_error(
            field: :google_access_token,
            message: "No Google access token available"
          )
        else
          # Define the process function that will be called for each batch of events
          process_batch_fn = fn events ->
            # Convert event data to the format expected by the CalendarEvent resource
            event_inputs =
              Enum.map(events, fn event_data ->
                %{
                  google_data: event_data,
                  user_id: user.id
                }
              end)

            # Process events in smaller chunks of 10 for database insertion
            event_inputs
            |> Enum.chunk_every(10)
            |> Enum.each(fn chunk ->
              Ash.bulk_create(
                chunk,
                JumpstartAi.Accounts.CalendarEvent,
                :create_from_google,
                upsert?: true,
                upsert_identity: :unique_google_event_per_user,
                upsert_fields: [
                  :summary,
                  :description,
                  :location,
                  :start_time,
                  :end_time,
                  :attendees,
                  :creator,
                  :organizer,
                  :status,
                  :html_link,
                  :google_created_at,
                  :google_updated_at
                ],
                actor: user,
                authorize?: false,
                return_records?: false,
                stop_on_error?: false
              )
            end)

            {:ok, length(event_inputs)}
          end

          # Get events from last 30 days and next 90 days
          time_min = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()
          time_max = DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601()

          # Use streaming approach to process events in batches
          case JumpstartAi.CalendarService.stream_user_events(user,
                 batch_size: 50,
                 max_results: 250,
                 time_min: time_min,
                 time_max: time_max,
                 process_fn: process_batch_fn
               ) do
            {:ok, total_processed} ->
              changeset
              |> Ash.Changeset.change_attribute(:calendar_synced_at, DateTime.utc_now())

            {:error, reason} ->
              changeset
              |> Ash.Changeset.add_error(
                field: :calendar_synced_at,
                message: "Failed to sync calendar events: #{inspect(reason)}"
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

    policy action(:system_update_tokens) do
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

    attribute :emails_synced_at, :utc_datetime_usec do
      allow_nil? true
    end

    attribute :contacts_synced_at, :utc_datetime_usec do
      allow_nil? true
    end

    attribute :calendar_synced_at, :utc_datetime_usec do
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

    has_many :contacts, JumpstartAi.Accounts.Contact do
      public? true
    end

    has_many :calendar_events, JumpstartAi.Accounts.CalendarEvent do
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
