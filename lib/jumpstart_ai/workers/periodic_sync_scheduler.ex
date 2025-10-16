defmodule JumpstartAi.Workers.PeriodicSyncScheduler do
  @moduledoc """
  Periodic sync scheduler that runs every 5 minutes to sync data for all users.

  This worker queries all users and enqueues individual sync jobs for each user:
  - EmailSync for Gmail emails
  - ContactSync for Google Contacts
  - CalendarSync for Google Calendar events
  - HubSpotSync for HubSpot contacts and notes

  All sync workers have built-in duplicate prevention using Ash identities and upserts.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  alias JumpstartAi.Accounts.User
  alias JumpstartAi.Workers.EmailSync
  # alias JumpstartAi.Workers.{ContactSync, CalendarSync, HubSpotSync}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("PeriodicSyncScheduler - Starting periodic sync for all users")

    # Query all users who have valid tokens for any of the services
    users = get_users_for_sync()
    user_count = length(users)

    Logger.info("PeriodicSyncScheduler - Found #{user_count} users to sync")

    if user_count > 0 do
      # Enqueue sync jobs for each user
      jobs_enqueued = enqueue_sync_jobs(users)
      Logger.info("PeriodicSyncScheduler - Enqueued #{jobs_enqueued} total sync jobs")
    else
      Logger.info("PeriodicSyncScheduler - No users found with valid tokens")
    end

    :ok
  end

  defp get_users_for_sync do
    # Query all users and then filter for those with valid tokens
    User
    |> Ash.Query.for_read(:read)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&user_needs_sync?/1)
  end

  defp user_needs_sync?(user) do
    # Check if user has valid tokens for any service
    google_token_valid? = not is_nil(user.google_access_token)
    hubspot_token_valid? = not is_nil(user.hubspot_access_token)

    google_token_valid? or hubspot_token_valid?
  end

  defp enqueue_sync_jobs(users) do
    users
    |> Enum.map(&enqueue_user_sync_jobs/1)
    |> List.flatten()
    |> length()
  end

  defp enqueue_user_sync_jobs(user) do
    jobs = []

    jobs =
      if user_has_valid_google_token?(user) do
        google_jobs = [
          # Stagger the jobs to avoid overwhelming the APIs
          {EmailSync, %{user_id: user.id}, 0},
          {ContactSync, %{user_id: user.id}, 30},
          {CalendarSync, %{user_id: user.id}, 60}
        ]

        jobs ++ google_jobs
      else
        jobs
      end

    jobs =
      if not is_nil(user.hubspot_access_token) do
        Logger.info("PeriodicSyncScheduler - Enqueuing HubSpot sync jobs for user #{user.id}")

        hubspot_jobs = [
          {HubSpotSync, %{user_id: user.id, sync_type: "contacts"}, 90}
        ]

        jobs ++ hubspot_jobs
      else
        Logger.info(
          "PeriodicSyncScheduler - No valid HubSpot token for user #{user.id}, skipping HubSpot sync jobs"
        )

        jobs
      end

    Enum.each(jobs, fn {worker_module, args, delay_seconds} ->
      case worker_module.new(args) |> Oban.insert(schedule_in: delay_seconds) do
        {:ok, _job} ->
          Logger.debug(
            "PeriodicSyncScheduler - Enqueued #{inspect(worker_module)} job for user #{user.id}"
          )

        {:error, error} ->
          Logger.error(
            "PeriodicSyncScheduler - Failed to enqueue #{inspect(worker_module)} job for user #{user.id}: #{inspect(error)}"
          )
      end
    end)

    # Schedule proactive agent to check for changes after all sync jobs complete
    # Use a delay of 180 seconds to ensure all sync jobs have completed
    after_sync_completed(user.id)

    jobs
  end

  defp after_sync_completed(user_id) do
    # After each sync, check for proactive opportunities by detecting actual changes
    # and enqueue individual ProactiveAgent jobs for each event
    cutoff_time = DateTime.add(DateTime.utc_now(), -5, :minute)

    jobs_enqueued = 0

    # Enqueue individual jobs for each new email
    jobs_enqueued =
      case get_recent_emails(user_id, cutoff_time) do
        [] ->
          jobs_enqueued

        emails ->
          Enum.each(emails, fn email ->
            event_data = %{
              "subject" => email.subject,
              "sender_email" => email.from_email,
              "sender_name" => email.from_name,
              "snippet" => email.snippet,
              "date" => email.date && DateTime.to_iso8601(email.date)
            }

            case JumpstartAi.Workers.ProactiveAgent.new(%{
                   user_id: user_id,
                   event_type: "new_email",
                   event_data: event_data
                 })
                 |> Oban.insert(schedule_in: 180, queue: :proactive_actions) do
              {:ok, _job} ->
                Logger.debug(
                  "PeriodicSyncScheduler - Enqueued ProactiveAgent job for new_email: #{email.subject}"
                )

              {:error, error} ->
                Logger.error(
                  "PeriodicSyncScheduler - Failed to enqueue ProactiveAgent job: #{inspect(error)}"
                )
            end
          end)

          jobs_enqueued + length(emails)
      end

    # Enqueue individual jobs for each new contact
    jobs_enqueued =
      case get_recent_contacts(user_id, cutoff_time) do
        [] ->
          jobs_enqueued

        contacts ->
          Enum.each(contacts, fn contact ->
            event_data = %{
              "name" => contact.name,
              "email" => contact.email
            }

            case JumpstartAi.Workers.ProactiveAgent.new(%{
                   user_id: user_id,
                   event_type: "new_contact",
                   event_data: event_data
                 })
                 |> Oban.insert(schedule_in: 180, queue: :proactive_actions) do
              {:ok, _job} ->
                Logger.debug(
                  "PeriodicSyncScheduler - Enqueued ProactiveAgent job for new_contact: #{contact.name}"
                )

              {:error, error} ->
                Logger.error(
                  "PeriodicSyncScheduler - Failed to enqueue ProactiveAgent job: #{inspect(error)}"
                )
            end
          end)

          jobs_enqueued + length(contacts)
      end

    # Enqueue individual jobs for each new calendar event
    jobs_enqueued =
      case get_recent_calendar_events(user_id, cutoff_time) do
        [] ->
          jobs_enqueued

        events ->
          Enum.each(events, fn event ->
            event_data = %{
              "summary" => event.summary,
              "start_time" => event.start_time && DateTime.to_iso8601(event.start_time),
              "attendees" => event.attendees
            }

            case JumpstartAi.Workers.ProactiveAgent.new(%{
                   user_id: user_id,
                   event_type: "new_calendar_event",
                   event_data: event_data
                 })
                 |> Oban.insert(schedule_in: 180, queue: :proactive_actions) do
              {:ok, _job} ->
                Logger.debug(
                  "PeriodicSyncScheduler - Enqueued ProactiveAgent job for new_calendar_event: #{event.summary}"
                )

              {:error, error} ->
                Logger.error(
                  "PeriodicSyncScheduler - Failed to enqueue ProactiveAgent job: #{inspect(error)}"
                )
            end
          end)

          jobs_enqueued + length(events)
      end

    if jobs_enqueued > 0 do
      Logger.info(
        "PeriodicSyncScheduler - Enqueued #{jobs_enqueued} ProactiveAgent jobs for user #{user_id}"
      )
    else
      Logger.debug(
        "PeriodicSyncScheduler - No recent changes detected for user #{user_id}, skipping ProactiveAgent"
      )
    end
  end

  defp get_recent_emails(user_id, cutoff_time) do
    case JumpstartAi.Accounts.Email
         |> Ash.Query.for_read(:read_user, %{user_id: user_id})
         |> Ash.Query.select([
           :id,
           :subject,
           :from_email,
           :from_name,
           :snippet,
           :date,
           :inserted_at
         ])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(50)
         |> Ash.read!(authorize?: false) do
      emails ->
        # Filter emails created after cutoff_time
        Enum.filter(emails, fn email ->
          DateTime.compare(email.inserted_at, cutoff_time) == :gt
        end)
        |> Enum.take(20)
    end
  rescue
    _ -> []
  end

  defp get_recent_contacts(user_id, cutoff_time) do
    # Try to get recent contacts - handle case where Contact resource might not exist
    try do
      case JumpstartAi.Accounts.Contact
           |> Ash.Query.for_read(:read_user, %{user_id: user_id})
           |> Ash.Query.select([:email, :name, :inserted_at])
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.Query.limit(20)
           |> Ash.read!(authorize?: false) do
        contacts ->
          # Filter contacts created after cutoff_time
          Enum.filter(contacts, fn contact ->
            DateTime.compare(contact.inserted_at, cutoff_time) == :gt
          end)
          |> Enum.take(10)
      end
    rescue
      _ -> []
    end
  end

  defp get_recent_calendar_events(user_id, cutoff_time) do
    # Try to get recent calendar events - handle case where CalendarEvent resource might not exist
    try do
      case JumpstartAi.Accounts.CalendarEvent
           |> Ash.Query.for_read(:read_user, %{user_id: user_id})
           |> Ash.Query.select([:summary, :start_time, :attendees, :inserted_at])
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.Query.limit(20)
           |> Ash.read!(authorize?: false) do
        events ->
          # Filter events created after cutoff_time
          Enum.filter(events, fn event ->
            DateTime.compare(event.inserted_at, cutoff_time) == :gt
          end)
          |> Enum.take(10)
      end
    rescue
      _ -> []
    end
  end

  defp user_has_valid_google_token?(user) do
    not is_nil(user.google_access_token)
  end
end
