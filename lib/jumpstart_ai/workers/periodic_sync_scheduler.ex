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
    jobs = if user_has_valid_google_token?(user) do
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
    jobs = if not is_nil(user.hubspot_access_token) do
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
          Logger.debug("PeriodicSyncScheduler - Enqueued #{inspect(worker_module)} job for user #{user.id}")
        
        {:error, error} ->
          Logger.error("PeriodicSyncScheduler - Failed to enqueue #{inspect(worker_module)} job for user #{user.id}: #{inspect(error)}")
      end
    end)

    jobs
  end

  defp user_has_valid_google_token?(user) do
    not is_nil(user.google_access_token)
  end
end