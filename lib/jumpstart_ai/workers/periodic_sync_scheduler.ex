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
  alias JumpstartAi.Workers.{EmailSync, ContactSync, CalendarSync, HubSpotSync}

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

    # Enqueue Google service sync jobs if user has valid Google token
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

    # Enqueue HubSpot sync job if user has valid HubSpot token  
    jobs =
      if not is_nil(user.hubspot_access_token) do
        hubspot_jobs = [
          # HubSpot contacts sync (notes sync is automatically scheduled after contacts)
          {HubSpotSync, %{user_id: user.id, sync_type: "contacts"}, 90}
        ]

        jobs ++ hubspot_jobs
      else
        jobs
      end

    # Insert all jobs for this user
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
    changes = detect_recent_changes(user_id)
    
    # Only enqueue ProactiveAgent if there are actual changes
    if map_size(changes) > 0 do
      case JumpstartAi.Workers.ProactiveAgent.new(%{user_id: user_id, changes: changes})
           |> Oban.insert(schedule_in: 180, queue: :proactive_actions) do
        {:ok, _job} ->
          Logger.debug("PeriodicSyncScheduler - Enqueued ProactiveAgent job for user #{user_id} with changes: #{inspect(Map.keys(changes))}")

        {:error, error} ->
          Logger.error(
            "PeriodicSyncScheduler - Failed to enqueue ProactiveAgent job for user #{user_id}: #{inspect(error)}"
          )
      end
    else
      Logger.debug("PeriodicSyncScheduler - No recent changes detected for user #{user_id}, skipping ProactiveAgent")
    end
  end

  defp detect_recent_changes(user_id) do
    # Detect changes from the last 5 minutes (slightly longer than sync interval)
    cutoff_time = DateTime.add(DateTime.utc_now(), -5, :minute)
    changes = %{}

    # Check for new emails
    changes = 
      case get_recent_emails(user_id, cutoff_time) do
        [] -> changes
        new_emails -> Map.put(changes, "new_emails", format_new_emails(new_emails))
      end

    # Check for new contacts  
    changes =
      case get_recent_contacts(user_id, cutoff_time) do
        [] -> changes
        new_contacts -> Map.put(changes, "new_contacts", format_new_contacts(new_contacts))
      end

    # Check for new calendar events
    changes =
      case get_recent_calendar_events(user_id, cutoff_time) do
        [] -> changes
        new_events -> Map.put(changes, "new_calendar_events", format_new_events(new_events))
      end

    changes
  end

  defp get_recent_emails(user_id, cutoff_time) do
    case JumpstartAi.Accounts.Email
         |> Ash.Query.for_read(:read_user, %{user_id: user_id})
         |> Ash.Query.select([:id, :subject, :from_email, :from_name, :snippet, :date, :inserted_at])
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

  defp format_new_emails(emails) do
    Enum.map(emails, fn email ->
      %{
        "subject" => email.subject,
        "sender_email" => email.from_email,
        "sender_name" => email.from_name,
        "snippet" => email.snippet,
        "date" => email.date && DateTime.to_iso8601(email.date)
      }
    end)
  end

  defp format_new_contacts(contacts) do
    Enum.map(contacts, fn contact ->
      %{
        "name" => contact.name,
        "email" => contact.email
      }
    end)
  end

  defp format_new_events(events) do
    Enum.map(events, fn event ->
      %{
        "summary" => event.summary,
        "start_time" => event.start_time && DateTime.to_iso8601(event.start_time),
        "attendees" => event.attendees
      }
    end)
  end

  defp user_has_valid_google_token?(user) do
    not is_nil(user.google_access_token)
  end
end
