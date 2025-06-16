defmodule JumpstartAi.CalendarService do
  @moduledoc """
  Service module for Google Calendar integration using OAuth tokens
  """

  alias JumpstartAi.CalendarClient

  @doc """
  Fetches and processes all events for a user
  """
  def fetch_user_events(user, opts \\ []) do
    case CalendarClient.fetch_events(user, opts) do
      {:ok, %{"items" => events}} when is_list(events) ->
        parsed_events = Enum.map(events, &parse_event_data/1)
        {:ok, parsed_events}

      {:ok, _response} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams events in batches, processing and yielding each batch as it's fetched.
  This allows for processing events in smaller chunks instead of loading all into memory.

  Options:
  - batch_size: Number of events to fetch per batch (default: 50)
  - max_results: Maximum total events to fetch (default: 250)
  - process_fn: Function to call with each batch of processed events
  - time_min: Minimum time for events (ISO string)
  - time_max: Maximum time for events (ISO string)
  - calendar_id: Calendar ID to fetch from (default: "primary")
  """
  def stream_user_events(user, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    max_results = Keyword.get(opts, :max_results, 250)
    process_fn = Keyword.get(opts, :process_fn, fn batch -> {:ok, batch} end)
    time_min = Keyword.get(opts, :time_min)
    time_max = Keyword.get(opts, :time_max)
    calendar_id = Keyword.get(opts, :calendar_id, "primary")

    stream_events_with_pagination(
      user,
      process_fn,
      batch_size,
      max_results,
      nil,
      0,
      time_min,
      time_max,
      calendar_id
    )
  end

  defp stream_events_with_pagination(
         user,
         process_fn,
         batch_size,
         max_results,
         page_token,
         processed_count,
         time_min,
         time_max,
         calendar_id
       ) do
    # Calculate how many events to fetch in this batch
    remaining = max_results - processed_count
    current_batch_size = min(batch_size, remaining)

    if current_batch_size <= 0 do
      {:ok, processed_count}
    else
      # Build request options with pagination
      opts = [maxResults: current_batch_size, calendar_id: calendar_id]
      opts = if page_token, do: Keyword.put(opts, :pageToken, page_token), else: opts
      opts = if time_min, do: Keyword.put(opts, :timeMin, time_min), else: opts
      opts = if time_max, do: Keyword.put(opts, :timeMax, time_max), else: opts

      case CalendarClient.fetch_events(user, opts) do
        {:ok, %{"items" => events, "nextPageToken" => next_token}} when is_list(events) ->
          case process_batch_of_events(events, process_fn) do
            {:ok, batch_count} ->
              new_processed_count = processed_count + batch_count

              # Continue with next page if we have more to fetch and there's a next page token
              if new_processed_count < max_results and next_token do
                stream_events_with_pagination(
                  user,
                  process_fn,
                  batch_size,
                  max_results,
                  next_token,
                  new_processed_count,
                  time_min,
                  time_max,
                  calendar_id
                )
              else
                {:ok, new_processed_count}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %{"items" => events}} when is_list(events) ->
          # No more pages available
          case process_batch_of_events(events, process_fn) do
            {:ok, batch_count} ->
              {:ok, processed_count + batch_count}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _response} ->
          # No events found
          {:ok, processed_count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp process_batch_of_events(events, process_fn) do
    parsed_events = Enum.map(events, &parse_event_data/1)

    case process_fn.(parsed_events) do
      {:ok, _result} -> {:ok, length(parsed_events)}
      {:error, reason} -> {:error, reason}
      :ok -> {:ok, length(parsed_events)}
    end
  end

  @doc """
  Creates a calendar event
  """
  def create_event(user, event_params, calendar_id \\ "primary") do
    event_data = format_event_for_api(event_params)

    case CalendarClient.create_event(user, event_data, calendar_id) do
      {:ok, event} -> {:ok, parse_event_data(event)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets user's calendar list
  """
  def get_user_calendars(user) do
    case CalendarClient.fetch_calendar_list(user) do
      {:ok, %{"items" => calendars}} -> {:ok, calendars}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds free time slots for the user
  """
  def find_free_time(
        user,
        time_min,
        time_max,
        duration_minutes \\ 60,
        calendar_ids \\ ["primary"]
      ) do
    case CalendarClient.fetch_freebusy(user, time_min, time_max, calendar_ids) do
      {:ok, %{"calendars" => calendars}} ->
        busy_times = extract_busy_times(calendars)
        free_slots = calculate_free_slots(time_min, time_max, busy_times, duration_minutes)
        {:ok, free_slots}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_event_data(event_data) do
    %{
      id: event_data["id"],
      summary: event_data["summary"],
      description: event_data["description"],
      location: event_data["location"],
      start_time: parse_datetime(event_data["start"]),
      end_time: parse_datetime(event_data["end"]),
      attendees: parse_attendees(event_data["attendees"]),
      creator: get_in(event_data, ["creator", "email"]),
      organizer: get_in(event_data, ["organizer", "email"]),
      status: event_data["status"],
      html_link: event_data["htmlLink"],
      created: parse_iso_datetime(event_data["created"]),
      updated: parse_iso_datetime(event_data["updated"])
    }
  end

  defp parse_datetime(%{"dateTime" => date_time}) do
    case DateTime.from_iso8601(date_time) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(%{"date" => date}) do
    case Date.from_iso8601(date) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_iso_datetime(nil), do: nil

  defp parse_iso_datetime(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) when is_list(attendees) do
    Enum.map(attendees, fn attendee ->
      %{
        email: attendee["email"],
        display_name: attendee["displayName"],
        response_status: attendee["responseStatus"]
      }
    end)
  end

  defp format_event_for_api(params) do
    base_event = %{
      "summary" => params[:title] || params[:summary],
      "description" => params[:description],
      "location" => params[:location]
    }

    # Add start and end times
    event_with_times =
      case {params[:start_time], params[:end_time]} do
        {start_time, end_time} when not is_nil(start_time) and not is_nil(end_time) ->
          Map.merge(base_event, %{
            "start" => %{"dateTime" => DateTime.to_iso8601(start_time)},
            "end" => %{"dateTime" => DateTime.to_iso8601(end_time)}
          })

        _ ->
          base_event
      end

    # Add attendees if provided
    case params[:attendees] do
      attendees when is_list(attendees) and length(attendees) > 0 ->
        formatted_attendees =
          Enum.map(attendees, fn
            email when is_binary(email) -> %{"email" => email}
            %{email: email} -> %{"email" => email}
            attendee -> attendee
          end)

        Map.put(event_with_times, "attendees", formatted_attendees)

      _ ->
        event_with_times
    end
  end

  defp extract_busy_times(calendars) do
    calendars
    |> Enum.flat_map(fn {_calendar_id, calendar_data} ->
      case calendar_data["busy"] do
        busy_periods when is_list(busy_periods) ->
          Enum.map(busy_periods, fn period ->
            %{
              start: parse_iso_datetime(period["start"]),
              end: parse_iso_datetime(period["end"])
            }
          end)

        _ ->
          []
      end
    end)
    |> Enum.reject(fn period -> is_nil(period.start) or is_nil(period.end) end)
    |> Enum.sort_by(& &1.start, DateTime)
  end

  defp calculate_free_slots(time_min, time_max, busy_times, duration_minutes) do
    with {:ok, start_time, _} <- DateTime.from_iso8601(time_min),
         {:ok, end_time, _} <- DateTime.from_iso8601(time_max) do
      # Create time slots and filter out busy ones
      duration_seconds = duration_minutes * 60

      generate_time_slots(start_time, end_time, duration_seconds)
      |> Enum.reject(fn slot ->
        Enum.any?(busy_times, fn busy ->
          slots_overlap?(slot, busy)
        end)
      end)
    else
      _ -> []
    end
  end

  defp generate_time_slots(start_time, end_time, duration_seconds) do
    if DateTime.compare(start_time, end_time) == :lt do
      slot_end = DateTime.add(start_time, duration_seconds, :second)

      if DateTime.compare(slot_end, end_time) != :gt do
        slot = %{start: start_time, end: slot_end}
        # 30-minute intervals
        next_start = DateTime.add(start_time, 30 * 60, :second)
        [slot | generate_time_slots(next_start, end_time, duration_seconds)]
      else
        []
      end
    else
      []
    end
  end

  defp slots_overlap?(slot, busy_period) do
    # Two time periods overlap if one starts before the other ends
    DateTime.compare(slot.start, busy_period.end) == :lt and
      DateTime.compare(busy_period.start, slot.end) == :lt
  end
end
