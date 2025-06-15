defmodule JumpstartAi.GoogleContactsService do
  @moduledoc """
  Service module for Google Contacts integration using OAuth tokens
  """

  alias JumpstartAi.GoogleContactsClient

  @doc """
  Fetches and processes all contacts for a user
  """
  def fetch_user_contacts(user, opts \\ []) do
    case GoogleContactsClient.fetch_contacts(user, opts) do
      {:ok, %{"connections" => connections}} when is_list(connections) ->
        contact_details =
          Enum.map(connections, fn connection ->
            parse_contact_data(connection)
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, contact_details}

      {:ok, _response} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams contacts in batches, processing and yielding each batch as it's fetched.
  This allows for processing contacts in smaller chunks instead of loading all into memory.

  Options:
  - batch_size: Number of contacts to fetch per batch (default: 50)
  - max_results: Maximum total contacts to fetch (default: 500)
  - process_fn: Function to call with each batch of processed contacts
  """
  def stream_user_contacts(user, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    max_results = Keyword.get(opts, :max_results, 500)
    process_fn = Keyword.get(opts, :process_fn, fn batch -> {:ok, batch} end)

    stream_contacts_with_pagination(user, process_fn, batch_size, max_results, nil, 0)
  end

  defp stream_contacts_with_pagination(
         user,
         process_fn,
         batch_size,
         max_results,
         page_token,
         processed_count
       ) do
    # Calculate how many contacts to fetch in this batch
    remaining = max_results - processed_count
    current_batch_size = min(batch_size, remaining)

    if current_batch_size <= 0 do
      {:ok, processed_count}
    else
      # Build request options with pagination
      opts = [pageSize: current_batch_size]
      opts = if page_token, do: Keyword.put(opts, :pageToken, page_token), else: opts

      case GoogleContactsClient.fetch_contacts(user, opts) do
        {:ok, %{"connections" => connections, "nextPageToken" => next_token}}
        when is_list(connections) ->
          case process_batch_of_contacts(connections, process_fn) do
            {:ok, batch_count} ->
              new_processed_count = processed_count + batch_count

              # Continue with next page if we have more to fetch and there's a next page token
              if new_processed_count < max_results and next_token do
                stream_contacts_with_pagination(
                  user,
                  process_fn,
                  batch_size,
                  max_results,
                  next_token,
                  new_processed_count
                )
              else
                {:ok, new_processed_count}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %{"connections" => connections}} when is_list(connections) ->
          # No more pages available
          case process_batch_of_contacts(connections, process_fn) do
            {:ok, batch_count} ->
              {:ok, processed_count + batch_count}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _response} ->
          # No contacts found
          {:ok, processed_count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_batch_of_contacts(connections, process_fn) do
    contact_details =
      connections
      |> Enum.map(&parse_contact_data/1)
      |> Enum.reject(&is_nil/1)

    case process_fn.(contact_details) do
      {:ok, _result} -> {:ok, length(contact_details)}
      {:error, reason} -> {:error, reason}
      :ok -> {:ok, length(contact_details)}
    end
  end

  defp parse_contact_data(connection) do
    # Extract basic information from Google People API format
    resource_name = connection["resourceName"]
    id = resource_name && String.replace(resource_name, "people/", "")

    # Extract names
    names = connection["names"] || []

    primary_name =
      Enum.find(names, fn name -> name["metadata"]["primary"] end) || List.first(names)

    # Extract email addresses
    email_addresses = connection["emailAddresses"] || []

    primary_email =
      Enum.find(email_addresses, fn email -> email["metadata"]["primary"] end) ||
        List.first(email_addresses)

    # Extract phone numbers
    phone_numbers = connection["phoneNumbers"] || []

    primary_phone =
      Enum.find(phone_numbers, fn phone -> phone["metadata"]["primary"] end) ||
        List.first(phone_numbers)

    # Extract organizations (for company info)
    organizations = connection["organizations"] || []

    primary_org =
      Enum.find(organizations, fn org -> org["metadata"]["primary"] end) ||
        List.first(organizations)

    # Extract metadata for created/updated times
    metadata = connection["metadata"] || %{}

    %{
      id: id,
      google_id: id,
      firstname: primary_name && primary_name["givenName"],
      lastname: primary_name && primary_name["familyName"],
      email: primary_email && primary_email["value"],
      phone: primary_phone && primary_phone["value"],
      company: primary_org && primary_org["name"],
      created_at:
        format_google_timestamp(
          metadata["sources"] && List.first(metadata["sources"]) &&
            List.first(metadata["sources"])["updateTime"]
        ),
      updated_at:
        format_google_timestamp(
          metadata["sources"] && List.first(metadata["sources"]) &&
            List.first(metadata["sources"])["updateTime"]
        )
    }
  end

  defp format_google_timestamp(nil), do: nil

  defp format_google_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end
end
