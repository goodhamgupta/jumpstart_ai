defmodule JumpstartAi.Workers.EmailSync do
  use Oban.Worker, queue: :email_sync, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case JumpstartAi.Accounts.User |> Ash.get(user_id) do
      {:ok, user} ->
        # Check if user still needs email sync
        if not is_nil(user.google_access_token) and 
           (is_nil(user.emails_synced_at) or user.email_sync_status == "pending") do
          case user |> Ash.Changeset.for_update(:sync_gmail_emails) |> Ash.update() do
            {:ok, _updated_user} -> :ok
            {:error, error} -> {:error, error}
          end
        else
          :ok
        end
      {:error, error} -> {:error, error}
    end
  end
end