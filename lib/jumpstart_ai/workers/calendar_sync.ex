defmodule JumpstartAi.Workers.CalendarSync do
  use Oban.Worker, queue: :calendar_sync, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    IO.puts("CalendarSync – starting job for user #{user_id}")

    case JumpstartAi.Accounts.User |> Ash.get(user_id, authorize?: false) do
      {:ok, user} ->
        IO.puts("CalendarSync – fetched user #{user_id}")

        needs_sync? = not is_nil(user.google_access_token)

        cond do
          is_nil(user.google_access_token) ->
            IO.puts("CalendarSync – user #{user_id} has no Google access token")
            :ok

          needs_sync? ->
            if is_nil(user.google_refresh_token) do
              IO.puts(
                "CalendarSync – user #{user_id} has no refresh token, but attempting sync with access token"
              )
            end

            IO.puts("CalendarSync – syncing Calendar for user #{user_id}")

            user
            |> Ash.Changeset.for_update(:sync_calendar_events, %{}, authorize?: false)
            |> Ash.update()
            |> case do
              {:ok, _updated_user} ->
                IO.puts("CalendarSync – sync succeeded for user #{user_id}")
                :ok

              {:error, error} ->
                IO.inspect("CalendarSync – sync failed for user #{user_id}: #{inspect(error)}")

                # If sync failed and we don't have a refresh token, log the issue
                if is_nil(user.google_refresh_token) do
                  IO.puts(
                    "CalendarSync – user #{user_id} has no refresh token for re-authentication"
                  )
                end

                {:error, error}
            end

          true ->
            IO.puts("CalendarSync – user #{user_id} doesn't need sync")
            :ok
        end

      {:error, error} ->
        IO.puts("CalendarSync – failed to fetch user #{user_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Schedule a calendar sync job for a user
  """
  def schedule_sync(user_id, delay_seconds \\ 0) do
    %{user_id: user_id}
    |> __MODULE__.new()
    |> Oban.insert(schedule_in: delay_seconds)
  end
end
