defmodule JumpstartAi.Workers.EmailSync do
  use Oban.Worker, queue: :email_sync, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    IO.puts("EmailSync – starting job for user #{user_id}")

    case JumpstartAi.Accounts.User |> Ash.get(user_id, authorize?: false) do
      {:ok, user} ->
        IO.puts("EmailSync – fetched user #{user_id}")

        needs_sync? =
          not is_nil(user.google_access_token) and
            not is_nil(user.google_refresh_token) and
            (is_nil(user.emails_synced_at) or user.email_sync_status == "pending")

        cond do
          is_nil(user.google_access_token) ->
            IO.puts("EmailSync – user #{user_id} has no Google access token")
            :ok

          is_nil(user.google_refresh_token) ->
            IO.puts(
              "EmailSync – user #{user_id} needs to re-authorize Google access for email sync"
            )

            user
            |> Ash.Changeset.for_update(:update, %{email_sync_status: "needs_reauth"},
              authorize?: false
            )
            |> Ash.update()
            |> case do
              {:ok, _} ->
                :ok

              {:error, error} ->
                IO.inspect(
                  "EmailSync – failed to update user #{user_id} status: #{inspect(error)}"
                )

                {:error, error}
            end

          needs_sync? ->
            IO.puts("EmailSync – syncing Gmail for user #{user_id}")

            user
            |> Ash.Changeset.for_update(:sync_gmail_emails, %{}, authorize?: false)
            |> Ash.update()
            |> case do
              {:ok, _updated_user} ->
                IO.puts("EmailSync – sync succeeded for user #{user_id}")
                :ok

              {:error, error} ->
                IO.inspect("EmailSync – sync failed for user #{user_id}: #{inspect(error)}")
                {:error, error}
            end

          true ->
            IO.puts("EmailSync – no sync needed for user #{user_id}")
            :ok
        end

      {:error, error} ->
        IO.inspect("EmailSync – cannot fetch user #{user_id}: #{inspect(error)}")
        {:error, error}
    end
  end
end
