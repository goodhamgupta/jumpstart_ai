defmodule JumpstartAi.GoogleContactsService do
  @moduledoc """
  Service module for Google Contacts integration using OAuth tokens
  """

  alias JumpstartAi.GoogleContactsClient
  require Logger

  @doc """
  Fetches and processes all contacts for a user
  """
  def fetch_user_contacts(user, opts \\ []) do
    Logger.debug("⏬  Fetching full contact list for #{inspect(user)} (opts=#{inspect(opts)})")

    case GoogleContactsClient.fetch_contacts(user, opts) do
      {:ok, %{"connections" => connections}} when is_list(connections) ->
        Logger.debug("📥  Received #{length(connections)} raw contacts")

        contact_details =
          connections
          |> Enum.map(&parse_contact_data/1)
          |> Enum.reject(&is_nil/1)

        Logger.info("✅  Parsed #{length(contact_details)} contacts for #{inspect(user)}")
        {:ok, contact_details}

      {:ok, _response} ->
        Logger.info("ℹ️   No contacts returned for #{inspect(user)}")
        {:ok, []}

      {:error, reason} ->
        Logger.error("❌  Failed fetching contacts for #{inspect(user)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Streams contacts in batches, processing and yielding each batch as it's fetched.

  Options:
    • :batch_size   – contacts per request (default 50)
    • :max_results  – hard cap on contacts (default 500)
    • :process_fn   – fn(batch) -> {:ok | :error, _}
  """
  def stream_user_contacts(user, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    max_results = Keyword.get(opts, :max_results, 500)
    process_fn = Keyword.get(opts, :process_fn, fn batch -> {:ok, batch} end)

    Logger.info(
      "🚿  Streaming contacts for #{inspect(user)} " <>
        "(batch_size=#{batch_size}, max_results=#{max_results})"
    )

    result =
      stream_contacts_with_pagination(user, process_fn, batch_size, max_results, nil, 0)

    Logger.info("🏁  Finished streaming for #{inspect(user)} → #{inspect(result)}")
    result
  end

  defp stream_contacts_with_pagination(
         user,
         process_fn,
         batch_size,
         max_results,
         page_token,
         processed_count
       ) do
    remaining = max_results - processed_count
    current_batch_size = min(batch_size, remaining)

    cond do
      current_batch_size <= 0 ->
        Logger.debug("🎉  Reached max_results (#{processed_count})")
        {:ok, processed_count}

      true ->
        opts = [pageSize: current_batch_size]
        opts = if page_token, do: Keyword.put(opts, :pageToken, page_token), else: opts

        Logger.debug(
          "🔗  Requesting page (token=#{inspect(page_token)}) " <>
            "size=#{current_batch_size}"
        )

        case GoogleContactsClient.fetch_contacts(user, opts) do
          {:ok, %{"connections" => connections, "nextPageToken" => next_token}}
          when is_list(connections) ->
            Logger.debug("📄  Got #{length(connections)} connections, next_page? #{!!next_token}")

            with {:ok, batch_count} <- process_batch_of_contacts(connections, process_fn) do
              new_total = processed_count + batch_count

              if new_total < max_results and next_token do
                stream_contacts_with_pagination(
                  user,
                  process_fn,
                  batch_size,
                  max_results,
                  next_token,
                  new_total
                )
              else
                {:ok, new_total}
              end
            else
              {:error, reason} ->
                Logger.error("❌  Batch processing failed: #{inspect(reason)}")
                {:error, reason}
            end

          {:ok, %{"connections" => connections}} when is_list(connections) ->
            Logger.debug("📄  Final page with #{length(connections)} connections")

            case process_batch_of_contacts(connections, process_fn) do
              {:ok, count} -> {:ok, processed_count + count}
              {:error, _} = e -> e
            end

          {:ok, _response} ->
            Logger.info("ℹ️   Empty page received")
            {:ok, processed_count}

          {:error, reason} ->
            Logger.error("❌  Error fetching page: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp process_batch_of_contacts(connections, process_fn) do
    contact_details =
      connections
      |> Enum.map(&parse_contact_data/1)
      |> Enum.reject(&is_nil/1)

    Logger.debug("⚙️   Processing batch of #{length(contact_details)} contacts")

    case process_fn.(contact_details) do
      {:ok, _res} ->
        Logger.debug("✅  Batch processed successfully")
        {:ok, length(contact_details)}

      {:error, reason} ->
        Logger.error("❌  Batch failed: #{inspect(reason)}")
        {:error, reason}

      :ok ->
        Logger.debug("✅  Batch processed successfully (returned :ok)")
        {:ok, length(contact_details)}
    end
  end

  defp parse_contact_data(connection) do
    # Extract basic information from Google People API format
    resource_name = connection["resourceName"]
    id = resource_name && String.replace(resource_name, "people/", "")

    names = connection["names"] || []
    emails = connection["emailAddresses"] || []
    phones = connection["phoneNumbers"] || []
    orgs = connection["organizations"] || []
    metadata = connection["metadata"] || %{}

    primary_name = Enum.find(names, & &1["metadata"]["primary"]) || List.first(names)
    primary_email = Enum.find(emails, & &1["metadata"]["primary"]) || List.first(emails)
    primary_phone = Enum.find(phones, & &1["metadata"]["primary"]) || List.first(phones)
    primary_org = Enum.find(orgs, & &1["metadata"]["primary"]) || List.first(orgs)

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
          metadata["sources"] &&
            List.first(metadata["sources"]) &&
            List.first(metadata["sources"])["updateTime"]
        ),
      updated_at:
        format_google_timestamp(
          metadata["sources"] &&
            List.first(metadata["sources"]) &&
            List.first(metadata["sources"])["updateTime"]
        )
    }
  end

  defp format_google_timestamp(nil), do: nil

  defp format_google_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end
end
