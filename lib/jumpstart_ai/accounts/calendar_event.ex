defmodule JumpstartAi.Accounts.CalendarEvent do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAi]

  alias JumpstartAi.TextUtils

  postgres do
    table "calendar_events"
    repo JumpstartAi.Repo
  end

  vectorize do
    # Combine event metadata and description for semantic search
    full_text do
      text fn event ->
        # Format attendees from JSON string
        attendees_text =
          case Jason.decode(event.attendees || "[]") do
            {:ok, attendees} when is_list(attendees) ->
              attendees
              |> Enum.map(fn attendee ->
                case attendee do
                  %{"email" => email} -> email
                  email when is_binary(email) -> email
                  _ -> "Unknown"
                end
              end)
              |> Enum.join(", ")

            _ ->
              "No attendees"
          end

        metadata = """
        Event: #{TextUtils.clean_text(event.summary || "No title")}
        Location: #{TextUtils.clean_text(event.location || "No location")}
        Start: #{if event.start_time, do: Calendar.strftime(event.start_time, "%Y-%m-%d %H:%M"), else: "Unknown"}
        End: #{if event.end_time, do: Calendar.strftime(event.end_time, "%Y-%m-%d %H:%M"), else: "Unknown"}
        Status: #{event.status || "Unknown"}
        Attendees: #{attendees_text}
        Organizer: #{event.organizer || "Unknown"}
        """

        description = TextUtils.clean_and_truncate(event.description || "", 4000)

        metadata <> "\n\nDescription:\n" <> description
      end

      used_attributes [
        :summary,
        :description,
        :location,
        :start_time,
        :end_time,
        :attendees,
        :organizer,
        :status
      ]
    end

    strategy :manual
    embedding_model JumpstartAi.OpenAiEmbeddingModel
  end

  actions do
    defaults [:read, :destroy]

    read :list_upcoming do
      description "List upcoming events for a user"
      argument :user_id, :uuid, allow_nil?: false
      argument :limit, :integer, default: 10

      filter expr(user_id == ^arg(:user_id) and start_time >= ^DateTime.utc_now())
      prepare build(sort: [start_time: :asc], limit: arg(:limit))
    end

    read :list_by_user do
      description "List all events for a user"
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :find_by_time_range do
      description "Find events within a time range"
      argument :user_id, :uuid, allow_nil?: false
      argument :start_time, :utc_datetime, allow_nil?: false
      argument :end_time, :utc_datetime, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 start_time >= ^arg(:start_time) and
                 end_time <= ^arg(:end_time)
             )

      prepare build(sort: [start_time: :asc])
    end

    create :create_from_google do
      description "Create calendar event from Google Calendar API data"

      accept [
        :user_id,
        :google_event_id,
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
      ]

      argument :google_data, :map, allow_nil?: false

      change fn changeset, _context ->
        google_data = Ash.Changeset.get_argument(changeset, :google_data)

        attendees_json =
          case google_data[:attendees] do
            attendees when is_list(attendees) -> Jason.encode!(attendees)
            _ -> "[]"
          end

        changeset
        |> Ash.Changeset.change_attribute(:google_event_id, google_data[:id])
        |> Ash.Changeset.change_attribute(:summary, google_data[:summary])
        |> Ash.Changeset.change_attribute(:description, google_data[:description])
        |> Ash.Changeset.change_attribute(:location, google_data[:location])
        |> Ash.Changeset.change_attribute(:start_time, google_data[:start_time])
        |> Ash.Changeset.change_attribute(:end_time, google_data[:end_time])
        |> Ash.Changeset.change_attribute(:attendees, attendees_json)
        |> Ash.Changeset.change_attribute(:creator, google_data[:creator])
        |> Ash.Changeset.change_attribute(:organizer, google_data[:organizer])
        |> Ash.Changeset.change_attribute(:status, google_data[:status])
        |> Ash.Changeset.change_attribute(:html_link, google_data[:html_link])
        |> Ash.Changeset.change_attribute(:google_created_at, google_data[:created])
        |> Ash.Changeset.change_attribute(:google_updated_at, google_data[:updated])
      end

      # Automatic vectorization after calendar event creation/update - only if data changed
      change after_action(fn changeset, event, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :summary,
                 :description,
                 :location,
                 :start_time,
                 :end_time,
                 :attendees,
                 :organizer,
                 :status
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changing_attribute?(changeset, field)
                 end)

               if data_changed do
                 case event
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(actor: %AshAi{}, authorize?: false) do
                   {:ok, updated_event} ->
                     {:ok, updated_event}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for calendar event #{event.id} from Google: #{inspect(error)}"
                     )

                     {:ok, event}
                 end
               else
                 {:ok, event}
               end
             end)
    end

    create :schedule_meeting do
      description "Schedule a new meeting"
      accept [:user_id, :summary, :description, :location, :start_time, :end_time]
      argument :attendee_emails, {:array, :string}, default: []

      change fn changeset, context ->
        attendee_emails = Ash.Changeset.get_argument(changeset, :attendee_emails)

        attendees_json =
          attendee_emails
          |> Enum.map(&%{email: &1})
          |> Jason.encode!()

        changeset = Ash.Changeset.change_attribute(changeset, :attendees, attendees_json)

        # After creating locally, sync to Google Calendar
        changeset
        |> Ash.Changeset.after_action(fn _changeset, event, _context ->
          case context.actor do
            %{id: user_id} ->
              # Get user to create event in Google Calendar
              case JumpstartAi.Accounts.User |> Ash.get(user_id, authorize?: false) do
                {:ok, user} ->
                  event_params = %{
                    title: event.summary,
                    description: event.description,
                    location: event.location,
                    start_time: event.start_time,
                    end_time: event.end_time,
                    attendees: attendee_emails
                  }

                  case JumpstartAi.CalendarService.create_event(user, event_params) do
                    {:ok, google_event} ->
                      # Update with Google event ID
                      event
                      |> Ash.Changeset.for_update(:update, %{google_event_id: google_event.id},
                        authorize?: false
                      )
                      |> Ash.update()

                    {:error, _reason} ->
                      # Keep local event even if Google sync fails
                      {:ok, event}
                  end

                {:error, _} ->
                  {:ok, event}
              end

            _ ->
              {:ok, event}
          end
        end)
      end
    end

    read :find_availability do
      description "Find available time slots for scheduling"
      argument :user_id, :uuid, allow_nil?: false
      argument :start_time, :utc_datetime, allow_nil?: false
      argument :end_time, :utc_datetime, allow_nil?: false
      argument :duration_minutes, :integer, default: 60

      # Return empty result set since this is handled by the AI agent directly
      filter expr(false)
    end

    action :generate_meeting_summary, :string do
      description """
      Generates a summary of the calendar event including key details and outcomes.
      """

      argument :summary, :string do
        allow_nil? true
        description "Event title/summary"
      end

      argument :description, :string do
        allow_nil? true
        description "Event description"
      end

      argument :location, :string do
        allow_nil? true
        description "Event location"
      end

      argument :start_time, :utc_datetime do
        allow_nil? true
        description "Event start time"
      end

      argument :end_time, :utc_datetime do
        allow_nil? true
        description "Event end time"
      end

      run prompt(
            fn _input, _context ->
              LangChain.ChatModels.ChatOpenAI.new!(%{
                model: "gpt-4.1-mini-2025-04-14",
                api_key: System.get_env("OPENAI_API_KEY"),
                timeout: 30_000,
                temperature: 0,
                max_tokens: 2000
              })
            end,
            tools: false,
            prompt: """
            Create a concise summary of this calendar event. Include the purpose, key participants, and any outcomes or next steps if mentioned.

            Event: <%= @input.arguments.summary || "Untitled Event" %>
            Location: <%= @input.arguments.location || "No location specified" %>
            Duration: <%= if @input.arguments.start_time && @input.arguments.end_time do %>
              <%= Calendar.strftime(@input.arguments.start_time, "%Y-%m-%d %H:%M") %> to <%= Calendar.strftime(@input.arguments.end_time, "%H:%M") %>
            <% else %>
              Time not specified
            <% end %>

            <%= if @input.arguments.description && String.trim(@input.arguments.description) != "" do %>
              Description:
              <%= @input.arguments.description %>
            <% else %>
              No description provided.
            <% end %>
            """
          )
    end

    action :semantic_search_calendar_events, {:array, :map} do
      description """
      Semantic search for calendar events using vector similarity. Searches event title, description, location, and attendee information for semantically similar content.
      """

      argument :query, :string do
        allow_nil? false
        description "The search query to find semantically similar calendar events"
      end

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of results to return (default: 10)"
      end

      argument :similarity_threshold, :float do
        allow_nil? true
        default 0.7
        description "Minimum similarity score (0.0 to 1.0, default: 0.7)"
      end

      argument :start_date, :date do
        allow_nil? true
        description "Optional: filter events starting from this date"
      end

      argument :end_date, :date do
        allow_nil? true
        description "Optional: filter events ending before this date"
      end

      run fn input, context ->
        user_id = context.actor.id
        search_query = input.arguments.query
        limit = input.arguments.limit || 10
        similarity_threshold = input.arguments.similarity_threshold || 0.7
        start_date = input.arguments[:start_date]
        end_date = input.arguments[:end_date]

        # Generate embedding for the search query
        case JumpstartAi.OpenAiEmbeddingModel.generate([search_query], []) do
          {:ok, [search_vector]} ->
            # Build SQL query with optional date filters
            base_sql = """
            SELECT id, summary, description, location, start_time, end_time, attendees, organizer, status
            FROM calendar_events
            WHERE user_id = $1
              AND full_text_vector IS NOT NULL
              AND (full_text_vector <=> $2) >= $3
            """

            {sql_query, params} =
              cond do
                start_date && end_date ->
                  start_datetime = DateTime.new!(start_date, ~T[00:00:00])
                  end_datetime = DateTime.new!(end_date, ~T[23:59:59])

                  {base_sql <>
                     " AND start_time >= $4 AND end_time <= $5 ORDER BY (full_text_vector <=> $2) DESC LIMIT $6",
                   [
                     Ecto.UUID.dump!(user_id),
                     search_vector,
                     similarity_threshold,
                     start_datetime,
                     end_datetime,
                     limit
                   ]}

                start_date ->
                  start_datetime = DateTime.new!(start_date, ~T[00:00:00])

                  {base_sql <>
                     " AND start_time >= $4 ORDER BY (full_text_vector <=> $2) DESC LIMIT $5",
                   [
                     Ecto.UUID.dump!(user_id),
                     search_vector,
                     similarity_threshold,
                     start_datetime,
                     limit
                   ]}

                end_date ->
                  end_datetime = DateTime.new!(end_date, ~T[23:59:59])

                  {base_sql <>
                     " AND end_time <= $4 ORDER BY (full_text_vector <=> $2) DESC LIMIT $5",
                   [
                     Ecto.UUID.dump!(user_id),
                     search_vector,
                     similarity_threshold,
                     end_datetime,
                     limit
                   ]}

                true ->
                  {base_sql <> " ORDER BY (full_text_vector <=> $2) DESC LIMIT $4",
                   [Ecto.UUID.dump!(user_id), search_vector, similarity_threshold, limit]}
              end

            case JumpstartAi.Repo.query(sql_query, params) do
              {:ok, %{rows: rows}} ->
                formatted_events =
                  Enum.map(rows, fn [
                                      id,
                                      summary,
                                      description,
                                      location,
                                      start_time,
                                      end_time,
                                      attendees,
                                      organizer,
                                      status
                                    ] ->
                    # Parse attendees from JSON string
                    attendees_list =
                      case Jason.decode(attendees || "[]") do
                        {:ok, parsed_attendees} when is_list(parsed_attendees) ->
                          parsed_attendees
                          |> Enum.map(fn attendee ->
                            case attendee do
                              %{"email" => email} -> email
                              email when is_binary(email) -> email
                              _ -> "Unknown"
                            end
                          end)
                          # Limit to first 5 attendees for brevity
                          |> Enum.take(5)

                        _ ->
                          []
                      end

                    %{
                      "id" => Ecto.UUID.load!(id),
                      "summary" => summary || "Untitled Event",
                      "location" => location,
                      "start_time" =>
                        start_time &&
                          if is_struct(start_time, DateTime) do
                            DateTime.to_iso8601(start_time)
                          else
                            NaiveDateTime.to_iso8601(start_time)
                          end,
                      "end_time" =>
                        end_time &&
                          if is_struct(end_time, DateTime) do
                            DateTime.to_iso8601(end_time)
                          else
                            NaiveDateTime.to_iso8601(end_time)
                          end,
                      "organizer" => organizer,
                      "status" => status,
                      "attendees" => attendees_list,
                      "description_preview" =>
                        case description do
                          nil -> nil
                          text when byte_size(text) > 200 -> String.slice(text, 0, 200) <> "..."
                          text -> text
                        end
                    }
                  end)

                {:ok, formatted_events}

              {:error, error} ->
                {:error, "Failed to search calendar events: #{inspect(error)}"}
            end

          {:error, error} ->
            {:error, "Failed to generate search embedding: #{inspect(error)}"}
        end
      end
    end

    update :update do
      accept [:summary, :description, :location, :start_time, :end_time, :attendees, :status]
      require_atomic? false

      # Trigger manual vectorization after update - only if vectorized fields changed
      change after_action(fn changeset, event, _context ->
               # Check if any vectorized fields actually changed
               vectorized_fields = [
                 :summary,
                 :description,
                 :location,
                 :start_time,
                 :end_time,
                 :attendees,
                 :organizer,
                 :status
               ]

               data_changed =
                 Enum.any?(vectorized_fields, fn field ->
                   Ash.Changeset.changing_attribute?(changeset, field)
                 end)

               if data_changed do
                 case event
                      |> Ash.Changeset.for_update(:vectorize, %{})
                      |> Ash.update(actor: %AshAi{}, authorize?: false) do
                   {:ok, updated_event} ->
                     {:ok, updated_event}

                   {:error, error} ->
                     require Logger

                     Logger.warning(
                       "Failed to update embeddings for calendar event #{event.id}: #{inspect(error)}"
                     )

                     {:ok, event}
                 end
               else
                 {:ok, event}
               end
             end)
    end

    update :vectorize do
      accept []
      change AshAi.Changes.Vectorize
      require_atomic? false
    end

    action :create_calendar_event, :map do
      description """
      Creates a new calendar event and saves it to Google Calendar. Returns event information.
      This is a comprehensive action for creating calendar events with attendees, location, and timing.
      """

      argument :title, :string do
        allow_nil? false
        description "Event title/summary"
      end

      argument :description, :string do
        allow_nil? true
        description "Event description/agenda"
      end

      argument :location, :string do
        allow_nil? true
        description "Event location (physical address or virtual meeting link)"
      end

      argument :start_time, :utc_datetime do
        allow_nil? false
        description "Event start time (UTC datetime)"
      end

      argument :end_time, :utc_datetime do
        allow_nil? false
        description "Event end time (UTC datetime)"
      end

      argument :attendee_emails, {:array, :string} do
        allow_nil? true
        default []
        description "List of attendee email addresses"
      end

      argument :calendar_id, :string do
        allow_nil? true
        default "primary"
        description "Calendar ID to create the event in (default: primary)"
      end

      argument :send_notifications, :boolean do
        allow_nil? true
        default true
        description "Whether to send email notifications to attendees (default: true)"
      end

      run fn input, context ->
        user = context.actor

        # Validate start and end times
        if DateTime.compare(input.arguments.start_time, input.arguments.end_time) != :lt do
          {:error, "Start time must be before end time"}
        else
          # Prepare event parameters for Google Calendar API
          event_params = %{
            title: input.arguments.title,
            description: input.arguments.description,
            location: input.arguments.location,
            start_time: input.arguments.start_time,
            end_time: input.arguments.end_time,
            attendees: input.arguments.attendee_emails || []
          }

          calendar_id = input.arguments.calendar_id || "primary"

          # Create event in Google Calendar
          case JumpstartAi.CalendarService.create_event(user, event_params, calendar_id) do
            {:ok, parsed_event} ->
              # Also create local record for sync
              local_event_params = %{
                user_id: user.id,
                google_event_id: parsed_event.id,
                summary: parsed_event.summary,
                description: parsed_event.description,
                location: parsed_event.location,
                start_time: parsed_event.start_time,
                end_time: parsed_event.end_time,
                attendees: Jason.encode!(parsed_event.attendees),
                creator: parsed_event.creator,
                organizer: parsed_event.organizer,
                status: parsed_event.status,
                html_link: parsed_event.html_link,
                google_created_at: parsed_event.created,
                google_updated_at: parsed_event.updated
              }

              case JumpstartAi.Accounts.CalendarEvent
                   |> Ash.Changeset.new()
                   |> Ash.Changeset.change_attribute(:user_id, user.id)
                   |> Ash.Changeset.for_create(:create_from_google, %{google_data: parsed_event})
                   |> Ash.create(actor: user, authorize?: false) do
                {:ok, _local_event} ->
                  {:ok,
                   %{
                     "status" => "success",
                     "message" => "Calendar event created successfully",
                     "event_id" => parsed_event.id,
                     "title" => parsed_event.summary,
                     "start_time" =>
                       parsed_event.start_time && DateTime.to_iso8601(parsed_event.start_time),
                     "end_time" =>
                       parsed_event.end_time && DateTime.to_iso8601(parsed_event.end_time),
                     "location" => parsed_event.location,
                     "attendees" => Enum.map(parsed_event.attendees, & &1.email),
                     "html_link" => parsed_event.html_link
                   }}

                {:error, _error} ->
                  # Event created in Google but failed to save locally - still return success
                  {:ok,
                   %{
                     "status" => "success",
                     "message" => "Calendar event created successfully (Google Calendar only)",
                     "event_id" => parsed_event.id,
                     "title" => parsed_event.summary,
                     "start_time" =>
                       parsed_event.start_time && DateTime.to_iso8601(parsed_event.start_time),
                     "end_time" =>
                       parsed_event.end_time && DateTime.to_iso8601(parsed_event.end_time),
                     "location" => parsed_event.location,
                     "attendees" => Enum.map(parsed_event.attendees, & &1.email),
                     "html_link" => parsed_event.html_link
                   }}
              end

            {:error, reason} ->
              {:error, "Failed to create calendar event: #{reason}"}
          end
        end
      end
    end

    action :list_calendar_events, {:array, :map} do
      description """
      Lists the latest calendar events for the user. Returns the 10 most recent events with key details.
      """

      argument :limit, :integer do
        allow_nil? true
        default 10
        description "Maximum number of calendar events to return (default: 10)"
      end

      run fn input, context ->
        user_id = context.actor.id
        limit = input.arguments[:limit] || 10

        case JumpstartAi.Accounts.CalendarEvent
             |> Ash.Query.for_read(:list_by_user, %{user_id: user_id})
             |> Ash.Query.select([
               :summary,
               :location,
               :start_time,
               :end_time,
               :attendees,
               :organizer,
               :status
             ])
             |> Ash.Query.sort(start_time: :desc)
             |> Ash.Query.limit(limit)
             |> Ash.read(actor: context.actor, authorize?: false) do
          {:ok, events} ->
            formatted_events =
              Enum.map(events, fn event ->
                # Parse attendees from JSON string  
                attendees_list =
                  case Jason.decode(event.attendees || "[]") do
                    {:ok, parsed_attendees} when is_list(parsed_attendees) ->
                      parsed_attendees
                      |> Enum.map(fn attendee ->
                        case attendee do
                          %{"email" => email} -> email
                          email when is_binary(email) -> email
                          _ -> "Unknown"
                        end
                      end)
                      # Limit to first 3 attendees for brevity
                      |> Enum.take(3)

                    _ ->
                      []
                  end

                %{
                  "summary" => event.summary || "Untitled Event",
                  "location" => event.location,
                  "start_time" => event.start_time && DateTime.to_iso8601(event.start_time),
                  "end_time" => event.end_time && DateTime.to_iso8601(event.end_time),
                  "organizer" => event.organizer,
                  "status" => event.status,
                  "attendees" => attendees_list
                }
              end)

            {:ok, formatted_events}

          {:error, reason} ->
            {:error, "Failed to list calendar events: #{inspect(reason)}"}
        end
      end
    end
  end

  policies do
    # Allow read access to user's own events
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Allow create/update/destroy access to user's own events
    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Special handling for action-based reads
    policy action(:find_availability) do
      authorize_if always()
    end

    bypass action_type(:read) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:ash_ai_update_embeddings) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:vectorize) do
      authorize_if AshAi.Checks.ActorIsAshAi
    end

    bypass action(:semantic_search_calendar_events) do
      authorize_if actor_present()
    end

    policy action(:create_calendar_event) do
      authorize_if actor_present()
    end

    policy action(:list_calendar_events) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    timestamps()

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :google_event_id, :string do
      allow_nil? true
      public? true
    end

    attribute :summary, :string do
      allow_nil? true
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :location, :string do
      allow_nil? true
      public? true
    end

    attribute :start_time, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :end_time, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :attendees, :string do
      description "JSON-encoded array of attendee objects"
      allow_nil? true
      default "[]"
    end

    attribute :creator, :string do
      allow_nil? true
    end

    attribute :organizer, :string do
      allow_nil? true
    end

    attribute :status, :string do
      allow_nil? true
      default "confirmed"
    end

    attribute :html_link, :string do
      allow_nil? true
    end

    attribute :google_created_at, :utc_datetime do
      allow_nil? true
    end

    attribute :google_updated_at, :utc_datetime do
      allow_nil? true
    end
  end

  relationships do
    belongs_to :user, JumpstartAi.Accounts.User do
      public? true
      allow_nil? false
    end
  end

  calculations do
    calculate :parsed_attendees, {:array, :map} do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          case Jason.decode(record.attendees || "[]") do
            {:ok, attendees} -> attendees
            _ -> []
          end
        end)
      end
    end

    calculate :duration_minutes, :integer do
      calculation fn records, _context ->
        Enum.map(records, fn record ->
          case {record.start_time, record.end_time} do
            {start_time, end_time} when not is_nil(start_time) and not is_nil(end_time) ->
              DateTime.diff(end_time, start_time, :minute)

            _ ->
              nil
          end
        end)
      end
    end
  end

  identities do
    identity :unique_google_event_per_user, [:user_id, :google_event_id]
  end
end
