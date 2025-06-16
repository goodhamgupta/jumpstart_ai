defmodule JumpstartAi.Workers.EmailSync do
  use Oban.Worker, queue: :email_sync, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    IO.puts("EmailSync – starting job for user #{user_id}")

    case JumpstartAi.Accounts.User |> Ash.get(user_id, authorize?: false) do
      {:ok, user} ->
        IO.puts("EmailSync – fetched user #{user_id}")

        needs_sync? = not is_nil(user.google_access_token)

        cond do
          is_nil(user.google_access_token) ->
            IO.puts("EmailSync – user #{user_id} has no Google access token")
            :ok

          needs_sync? ->
            if is_nil(user.google_refresh_token) do
              IO.puts(
                "EmailSync – user #{user_id} has no refresh token, but attempting sync with access token"
              )
            end

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

                # If sync failed and we don't have a refresh token, log the issue
                if is_nil(user.google_refresh_token) do
                  IO.puts(
                    "EmailSync – user #{user_id} has no refresh token for re-authentication"
                  )
                end

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
