defmodule JumpstartAi.Workers.HubSpotSync do
  @moduledoc """
  Background worker for syncing HubSpot contacts and notes.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger
  alias JumpstartAi.HubSpotService
  alias JumpstartAi.Accounts.{User, Contact, ContactNote}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "sync_type" => "contacts"}}) do
    Logger.info("HubSpot Sync - Starting contact sync for user #{user_id}")

    with {:ok, user} <- get_user(user_id),
         {:ok, contacts} <- HubSpotService.fetch_contacts(user) do
      contacts_synced =
        contacts
        |> Enum.map(&sync_contact(user, &1))
        |> Enum.count(fn result -> match?({:ok, _}, result) end)

      Logger.info(
        "HubSpot Sync - Successfully synced #{contacts_synced} contacts for user #{user_id}"
      )

      # Schedule notes sync for this user
      %{user_id: user_id, sync_type: "notes"}
      |> __MODULE__.new()
      |> Oban.insert(schedule_in: 30)

      :ok
    else
      {:error, :no_hubspot_token} ->
        Logger.info("HubSpot Sync - User #{user_id} has no HubSpot token, skipping sync")
        :ok

      {:error, reason} ->
        Logger.error("HubSpot Sync - Contact sync failed for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "sync_type" => "notes"}}) do
    Logger.info("HubSpot Sync - Starting notes sync for user #{user_id}")

    with {:ok, user} <- get_user(user_id) do
      # Get all contacts for this user
      contacts =
        Contact
        |> Ash.Query.for_read(:get_by_user, %{user_id: user.id})
        |> Ash.read!(authorize?: false)

      # Only sync notes for HubSpot contacts - Google contacts won't have notes in HubSpot
      hubspot_contacts = Enum.filter(contacts, fn contact -> contact.source == "hubspot" end)

      Logger.info(
        "HubSpot Sync - Found #{length(hubspot_contacts)} HubSpot contacts out of #{length(contacts)} total contacts"
      )

      notes_synced =
        hubspot_contacts
        |> Enum.flat_map(&sync_contact_notes(user, &1))
        |> Enum.count(fn result -> match?({:ok, _}, result) end)

      Logger.info("HubSpot Sync - Successfully synced #{notes_synced} notes for user #{user_id}")
      :ok
    else
      {:error, reason} ->
        Logger.error("HubSpot Sync - Notes sync failed for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    # Default to contacts sync if no sync_type specified
    perform(%Oban.Job{args: %{"user_id" => user_id, "sync_type" => "contacts"}})
  end

  # Helper functions

  defp get_user(user_id) do
    Logger.info("HubSpot Sync - Looking up user with ID: #{inspect(user_id)}")

    # Convert string UUID to proper format if needed
    parsed_user_id =
      case user_id do
        id when is_binary(id) ->
          case Ecto.UUID.cast(id) do
            {:ok, uuid} ->
              uuid

            :error ->
              Logger.error("HubSpot Sync - Invalid UUID format: #{inspect(id)}")
              id
          end

        id ->
          id
      end

    Logger.info("HubSpot Sync - Parsed user ID: #{inspect(parsed_user_id)}")

    case User
         |> Ash.Query.for_read(:get_by_id, %{id: parsed_user_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, user} when not is_nil(user) ->
        Logger.info("HubSpot Sync - Found user: #{user.email}")

        Logger.info(
          "HubSpot Sync - User has HubSpot token: #{not is_nil(user.hubspot_access_token)}"
        )

        {:ok, user}

      {:ok, nil} ->
        Logger.error("HubSpot Sync - User not found with ID: #{inspect(parsed_user_id)}")
        {:error, :user_not_found}

      {:error, error} ->
        Logger.error("HubSpot Sync - Error reading user: #{inspect(error)}")
        {:error, error}
    end
  end

  defp sync_contact(user, hubspot_contact) do
    contact_data = Map.put(hubspot_contact, :user_id, user.id)

    Contact
    |> Ash.Changeset.for_create(:create_from_hubspot, %{hubspot_data: contact_data})
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, contact} ->
        Logger.debug("HubSpot Sync - Synced contact #{hubspot_contact.external_id}")
        {:ok, contact}

      {:error, error} ->
        Logger.error(
          "HubSpot Sync - Failed to sync contact #{hubspot_contact.external_id}: #{inspect(error)}"
        )

        {:error, error}
    end
  end

  defp sync_contact_notes(user, contact) do
    Logger.debug("HubSpot Sync - Fetching notes for contact #{contact.external_id}")

    case HubSpotService.fetch_contact_notes(user, contact.external_id) do
      {:ok, notes} ->
        Logger.debug(
          "HubSpot Sync - Found #{length(notes)} notes for contact #{contact.external_id}"
        )

        # Process each note and create ContactNote records
        notes
        |> Enum.map(fn note ->
          note_data = Map.put(note, :contact_id, contact.id)

          ContactNote
          |> Ash.Changeset.for_create(:create_from_hubspot, %{hubspot_note_data: note_data})
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, contact_note} ->
              Logger.debug(
                "HubSpot Sync - Created note #{note.hubspot_note_id} for contact #{contact.external_id}"
              )

              {:ok, contact_note}

            {:error, error} ->
              Logger.error(
                "HubSpot Sync - Failed to create note #{note.hubspot_note_id} for contact #{contact.external_id}: #{inspect(error)}"
              )

              {:error, error}
          end
        end)

      {:error, reason} ->
        Logger.error(
          "HubSpot Sync - Failed to fetch notes for contact #{contact.external_id}: #{inspect(reason)}"
        )

        []
    end
  end

  @doc """
  Schedule a HubSpot sync job for a user.
  """
  def schedule_sync(user_id, sync_type \\ "contacts", schedule_in \\ 0) do
    %{user_id: user_id, sync_type: sync_type}
    |> __MODULE__.new()
    |> Oban.insert(schedule_in: schedule_in)
  end
end
