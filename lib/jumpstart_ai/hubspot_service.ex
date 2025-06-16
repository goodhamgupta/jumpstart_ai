defmodule JumpstartAi.HubSpotService do
  @moduledoc """
  HubSpot API client for managing contacts and other CRM operations.
  """

  require Logger

  @base_url "https://api.hubapi.com"

  @doc """
  Fetches all contacts from HubSpot for a given user.
  """
  def fetch_contacts(user, opts \\ []) do
    Logger.info("HubSpot Service - Starting contact fetch for user #{user.id}")
    Logger.info("HubSpot Service - User email: #{user.email}")
    Logger.info("HubSpot Service - Has access token: #{not is_nil(user.hubspot_access_token)}")
    Logger.info("HubSpot Service - Token expires at: #{inspect(user.hubspot_token_expires_at)}")

    with {:ok, access_token} <- get_valid_access_token(user) do
      limit = Keyword.get(opts, :limit, 100)

      properties =
        Keyword.get(opts, :properties, [
          "email",
          "firstname",
          "lastname",
          "phone",
          "company",
          "lifecyclestage"
        ])

      Logger.info(
        "HubSpot Service - Got valid access token, fetching contacts with limit #{limit}"
      )

      fetch_all_contacts(access_token, limit, properties)
    else
      {:error, reason} ->
        Logger.error("HubSpot Service - Failed to get valid access token: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetches a specific contact by ID from HubSpot.
  """
  def fetch_contact(user, contact_id) do
    with {:ok, access_token} <- get_valid_access_token(user) do
      url = "#{@base_url}/crm/v3/objects/contacts/#{contact_id}"

      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]

      case HTTPoison.get(url, headers) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, contact_data} ->
              {:ok, normalize_contact(contact_data)}

            {:error, error} ->
              Logger.error("HubSpot - Failed to parse contact response: #{inspect(error)}")
              {:error, :parse_error}
          end

        {:ok, %HTTPoison.Response{status_code: 404}} ->
          {:error, :not_found}

        {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
          Logger.error("HubSpot - Contact fetch failed with status #{status_code}: #{body}")
          {:error, {:api_error, status_code}}

        {:error, error} ->
          Logger.error("HubSpot - Network error fetching contact: #{inspect(error)}")
          {:error, :network_error}
      end
    end
  end

  @doc """
  Creates a new contact in HubSpot.
  """
  def create_contact(user, contact_data) do
    with {:ok, access_token} <- get_valid_access_token(user) do
      url = "#{@base_url}/crm/v3/objects/contacts"

      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]

      body =
        Jason.encode!(%{
          "properties" => contact_data
        })

      case HTTPoison.post(url, body, headers) do
        {:ok, %HTTPoison.Response{status_code: 201, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, contact} ->
              {:ok, normalize_contact(contact)}

            {:error, error} ->
              Logger.error("HubSpot - Failed to parse create contact response: #{inspect(error)}")
              {:error, :parse_error}
          end

        {:ok, %HTTPoison.Response{status_code: status_code, body: response_body}} ->
          Logger.error(
            "HubSpot - Contact creation failed with status #{status_code}: #{response_body}"
          )

          {:error, {:api_error, status_code}}

        {:error, error} ->
          Logger.error("HubSpot - Network error creating contact: #{inspect(error)}")
          {:error, :network_error}
      end
    end
  end

  @doc """
  Updates an existing contact in HubSpot.
  """
  def update_contact(user, contact_id, contact_data) do
    with {:ok, access_token} <- get_valid_access_token(user) do
      url = "#{@base_url}/crm/v3/objects/contacts/#{contact_id}"

      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]

      body =
        Jason.encode!(%{
          "properties" => contact_data
        })

      case HTTPoison.patch(url, body, headers) do
        {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, contact} ->
              {:ok, normalize_contact(contact)}

            {:error, error} ->
              Logger.error("HubSpot - Failed to parse update contact response: #{inspect(error)}")
              {:error, :parse_error}
          end

        {:ok, %HTTPoison.Response{status_code: 404}} ->
          {:error, :not_found}

        {:ok, %HTTPoison.Response{status_code: status_code, body: response_body}} ->
          Logger.error(
            "HubSpot - Contact update failed with status #{status_code}: #{response_body}"
          )

          {:error, {:api_error, status_code}}

        {:error, error} ->
          Logger.error("HubSpot - Network error updating contact: #{inspect(error)}")
          {:error, :network_error}
      end
    end
  end

  @doc """
  Fetches notes/engagements for a specific contact from HubSpot.
  """
  def fetch_contact_notes(user, contact_external_id) do
    with {:ok, access_token} <- get_valid_access_token(user) do
      # Get all notes and then filter for this contact's associations client-side
      # HubSpot's associations API requires the contact to be associated with notes
      case fetch_all_notes(access_token, contact_external_id) do
        {:ok, notes} ->
          Logger.debug("HubSpot - Found #{length(notes)} notes for contact #{contact_external_id}")
          {:ok, notes}

        {:error, reason} ->
          Logger.error("HubSpot - Failed to fetch notes for contact #{contact_external_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Searches for contacts in HubSpot by query.
  """
  def search_contacts(user, query, opts \\ []) do
    with {:ok, access_token} <- get_valid_access_token(user) do
      url = "#{@base_url}/crm/v3/objects/contacts/search"

      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]

      limit = Keyword.get(opts, :limit, 10)

      properties =
        Keyword.get(opts, :properties, ["email", "firstname", "lastname", "phone", "company"])

      body =
        Jason.encode!(%{
          "query" => query,
          "limit" => limit,
          "properties" => properties
        })

      case HTTPoison.post(url, body, headers) do
        {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"results" => contacts}} ->
              normalized_contacts = Enum.map(contacts, &normalize_contact/1)
              {:ok, normalized_contacts}

            {:error, error} ->
              Logger.error("HubSpot - Failed to parse search response: #{inspect(error)}")
              {:error, :parse_error}
          end

        {:ok, %HTTPoison.Response{status_code: status_code, body: response_body}} ->
          Logger.error(
            "HubSpot - Contact search failed with status #{status_code}: #{response_body}"
          )

          {:error, {:api_error, status_code}}

        {:error, error} ->
          Logger.error("HubSpot - Network error searching contacts: #{inspect(error)}")
          {:error, :network_error}
      end
    end
  end

  # Private helper functions

  defp fetch_all_notes(access_token, contact_external_id) do
    # Use the associations API to get notes for this specific contact
    url = "#{@base_url}/crm/v4/objects/contacts/#{contact_external_id}/associations/notes"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => associated_notes}} ->
            # Now fetch the actual note details
            note_ids = Enum.map(associated_notes, fn assoc -> assoc["toObjectId"] end)
            fetch_notes_by_ids(access_token, note_ids)

          {:error, error} ->
            Logger.error("HubSpot - Failed to parse note associations: #{inspect(error)}")
            {:error, :parse_error}
        end

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        # No associations found - this is normal, just return empty list
        {:ok, []}

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("HubSpot - Note associations fetch failed with status #{status_code}: #{body}")
        {:error, {:api_error, status_code}}

      {:error, error} ->
        Logger.error("HubSpot - Network error fetching note associations: #{inspect(error)}")
        {:error, :network_error}
    end
  end

  defp fetch_notes_by_ids(_access_token, []), do: {:ok, []}

  defp fetch_notes_by_ids(access_token, note_ids) when is_list(note_ids) do
    # Use batch read to get note details efficiently
    url = "#{@base_url}/crm/v3/objects/notes/batch/read"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    inputs = Enum.map(note_ids, fn id -> %{"id" => id} end)

    body = Jason.encode!(%{
      "inputs" => inputs,
      "properties" => ["hs_note_body", "hs_created_at", "hs_lastmodifieddate", "hubspot_owner_id"]
    })

    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"results" => notes}} ->
            normalized_notes = Enum.map(notes, &normalize_note/1)
            {:ok, normalized_notes}

          {:error, error} ->
            Logger.error("HubSpot - Failed to parse batch notes response: #{inspect(error)}")
            {:error, :parse_error}
        end

      {:ok, %HTTPoison.Response{status_code: status_code, body: response_body}} ->
        Logger.error("HubSpot - Batch notes fetch failed with status #{status_code}: #{response_body}")
        {:error, {:api_error, status_code}}

      {:error, error} ->
        Logger.error("HubSpot - Network error fetching batch notes: #{inspect(error)}")
        {:error, :network_error}
    end
  end

  defp fetch_all_contacts(access_token, limit, properties, after_cursor \\ nil, accumulated \\ []) do
    url = build_contacts_url(limit, properties, after_cursor)

    Logger.info("HubSpot Service - Making API request to: #{url}")

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Logger.info("HubSpot Service - Successfully fetched contacts page")

        case Jason.decode(body) do
          {:ok, %{"results" => contacts} = response} ->
            Logger.info("HubSpot Service - Found #{length(contacts)} contacts in this page")
            normalized_contacts = Enum.map(contacts, &normalize_contact/1)
            all_contacts = accumulated ++ normalized_contacts
            Logger.info("HubSpot Service - Total contacts so far: #{length(all_contacts)}")

            # Check if there are more pages
            case get_in(response, ["paging", "next", "after"]) do
              nil ->
                Logger.info(
                  "HubSpot Service - No more pages, returning #{length(all_contacts)} total contacts"
                )

                {:ok, all_contacts}

              next_cursor ->
                Logger.info("HubSpot Service - Found next page cursor, continuing pagination")
                fetch_all_contacts(access_token, limit, properties, next_cursor, all_contacts)
            end

          {:error, error} ->
            Logger.error("HubSpot - Failed to parse contacts response: #{inspect(error)}")
            {:error, :parse_error}
        end

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("HubSpot - Contacts fetch failed with status #{status_code}: #{body}")
        {:error, {:api_error, status_code}}

      {:error, error} ->
        Logger.error("HubSpot - Network error fetching contacts: #{inspect(error)}")
        {:error, :network_error}
    end
  end

  defp build_contacts_url(limit, properties, after_cursor) do
    base = "#{@base_url}/crm/v3/objects/contacts"

    query_params = [
      {"limit", to_string(limit)},
      {"properties", Enum.join(properties, ",")},
      {"archived", "false"}
    ]

    query_params =
      if after_cursor do
        [{"after", after_cursor} | query_params]
      else
        query_params
      end

    query_string =
      query_params
      |> Enum.map(fn {key, value} -> "#{key}=#{URI.encode(value)}" end)
      |> Enum.join("&")

    "#{base}?#{query_string}"
  end

  defp normalize_note(note_data) do
    properties = note_data["properties"] || %{}

    %{
      hubspot_note_id: note_data["id"],
      content: properties["hs_note_body"] || "",
      note_type: "NOTE",
      created_at: parse_datetime(properties["hs_created_at"]),
      updated_at: parse_datetime(properties["hs_lastmodifieddate"]),
      hubspot_owner_id: properties["hubspot_owner_id"]
    }
  end

  defp normalize_contact(contact_data) do
    properties = contact_data["properties"] || %{}

    %{
      id: contact_data["id"],
      external_id: contact_data["id"],
      email: properties["email"],
      firstname: properties["firstname"],
      lastname: properties["lastname"],
      phone: properties["phone"],
      company: properties["company"],
      lifecycle_stage: properties["lifecyclestage"],
      created_at: parse_datetime(contact_data["createdAt"]),
      updated_at: parse_datetime(contact_data["updatedAt"]),
      archived: contact_data["archived"] || false,
      properties: properties
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp get_valid_access_token(user) do
    Logger.info("HubSpot Service - Checking access token validity")
    Logger.info("HubSpot Service - Has access token: #{not is_nil(user.hubspot_access_token)}")
    Logger.info("HubSpot Service - Token expires at: #{inspect(user.hubspot_token_expires_at)}")

    Logger.info(
      "HubSpot Service - Token expired: #{token_expired?(user.hubspot_token_expires_at)}"
    )

    cond do
      is_nil(user.hubspot_access_token) ->
        Logger.warning("HubSpot Service - No HubSpot access token found")
        {:error, :no_hubspot_token}

      token_expired?(user.hubspot_token_expires_at) ->
        Logger.info("HubSpot Service - Token expired, attempting refresh")
        refresh_hubspot_token(user)

      true ->
        Logger.info("HubSpot Service - Using valid access token")
        {:ok, user.hubspot_access_token}
    end
  end

  defp token_expired?(nil), do: true

  defp token_expired?(expires_at) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp refresh_hubspot_token(user) do
    Logger.info("HubSpot Service - Attempting to refresh token for user #{user.id}")
    Logger.info("HubSpot Service - Has refresh token: #{not is_nil(user.hubspot_refresh_token)}")

    if user.hubspot_refresh_token do
      url = "#{@base_url}/oauth/v1/token"

      headers = [
        {"Content-Type", "application/x-www-form-urlencoded"}
      ]

      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => user.hubspot_refresh_token,
          "client_id" => Application.get_env(:jumpstart_ai, :hubspot_client_id),
          "client_secret" => Application.get_env(:jumpstart_ai, :hubspot_client_secret)
        })

      case HTTPoison.post(url, body, headers) do
        {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
          case Jason.decode(response_body) do
            {:ok, %{"access_token" => access_token} = tokens} ->
              expires_in = tokens["expires_in"] || 21600
              expires_at = DateTime.utc_now() |> DateTime.add(expires_in, :second)

              # Update user with new tokens
              user
              |> Ash.Changeset.for_update(:update, %{
                hubspot_access_token: access_token,
                hubspot_refresh_token: tokens["refresh_token"] || user.hubspot_refresh_token,
                hubspot_token_expires_at: expires_at
              })
              |> Ash.update()
              |> case do
                {:ok, _updated_user} ->
                  Logger.info("HubSpot - Successfully refreshed access token")
                  {:ok, access_token}

                {:error, error} ->
                  Logger.error(
                    "HubSpot - Failed to update user with new tokens: #{inspect(error)}"
                  )

                  {:error, :token_update_failed}
              end

            {:error, error} ->
              Logger.error("HubSpot - Failed to parse token refresh response: #{inspect(error)}")
              {:error, :token_refresh_failed}
          end

        {:ok, %HTTPoison.Response{status_code: status_code, body: response_body}} ->
          Logger.error(
            "HubSpot - Token refresh failed with status #{status_code}: #{response_body}"
          )

          {:error, :token_refresh_failed}

        {:error, error} ->
          Logger.error("HubSpot - Network error refreshing token: #{inspect(error)}")
          {:error, :network_error}
      end
    else
      Logger.error("HubSpot - No refresh token available for user #{user.id}")
      {:error, :no_refresh_token}
    end
  end
end
