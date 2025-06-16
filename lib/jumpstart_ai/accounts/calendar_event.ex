defmodule JumpstartAi.Accounts.CalendarEvent do
  use Ash.Resource,
    otp_app: :jumpstart_ai,
    domain: JumpstartAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "calendar_events"
    repo JumpstartAi.Repo
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

    update :update do
      accept [:summary, :description, :location, :start_time, :end_time, :attendees, :status]
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
