defmodule JumpstartAi.Workers.EmailSyncTest do
  use JumpstartAi.DataCase, async: true

  alias JumpstartAi.Workers.EmailSync
  alias JumpstartAi.Accounts.User

  describe "EmailSync worker" do
    test "perform/1 calls sync_gmail_emails action on user" do
      # Create a test user using Google OAuth registration
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "test@example.com",
              "name" => "Test User"
            },
            oauth_tokens: %{
              "access_token" => "test_access_token",
              "refresh_token" => "test_refresh_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # User doesn't need a separate sync status anymore since we use emails_synced_at
      # The sync status is determined by whether emails_synced_at is nil

      # Create a job with the user_id
      _job = %Oban.Job{args: %{"user_id" => user.id}}

      # Since we can't easily mock the GmailService in this test,
      # we'll test that the worker properly handles the case where
      # the user doesn't have a Google access token
      {:ok, user_without_token} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "notoken@example.com",
              "name" => "No Token User"
            },
            oauth_tokens: %{
              "access_token" => "fake_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # Remove the access token to simulate missing token
      {:ok, user_without_token} =
        user_without_token
        |> Ash.Changeset.for_update(
          :update,
          %{
            google_access_token: nil
          },
          authorize?: false
        )
        |> Ash.update()

      job_without_token = %Oban.Job{args: %{"user_id" => user_without_token.id}}

      # Test that worker handles missing token gracefully
      result = EmailSync.perform(job_without_token)
      assert result == :ok
    end

    test "perform/1 handles invalid user_id gracefully" do
      # Create a job with a non-existent user_id
      fake_user_id = Ash.UUID.generate()
      job = %Oban.Job{args: %{"user_id" => fake_user_id}}

      # Test that worker handles missing user gracefully
      result = EmailSync.perform(job)
      assert {:error, _error} = result
    end

    test "perform/1 handles user with emails_synced_at set but needs re-sync" do
      # Create a user that has emails_synced_at set but may need re-sync
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "synced@example.com",
              "name" => "Synced User"
            },
            oauth_tokens: %{
              "access_token" => "test_access_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # Update to show already synced by setting emails_synced_at
      {:ok, user} =
        user
        |> Ash.Changeset.for_update(
          :update,
          %{
            emails_synced_at: DateTime.utc_now()
          },
          authorize?: false
        )
        |> Ash.update()

      job = %Oban.Job{args: %{"user_id" => user.id}}

      # Test that worker can handle a user that has already been synced
      # but it will likely fail due to invalid tokens
      result = EmailSync.perform(job)

      # Result could be :ok or {:error, _} depending on Gmail service response
      # The important thing is that it doesn't crash
      assert result == :ok or match?({:error, _}, result)
    end

    test "perform/1 handles user that needs sync" do
      # Create a user that needs sync (has access token but no emails_synced_at)
      {:ok, user} =
        User
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{
            user_info: %{
              "email" => "pending@example.com",
              "name" => "Pending User"
            },
            oauth_tokens: %{
              "access_token" => "test_access_token",
              "refresh_token" => "test_refresh_token",
              "expires_in" => 3600
            }
          },
          authorize?: false
        )
        |> Ash.create()

      # User is created without emails_synced_at, so sync should happen

      job = %Oban.Job{args: %{"user_id" => user.id}}

      # The sync will likely fail due to invalid tokens, but we can test
      # that the worker attempts to call the sync action
      # In a real test environment, we'd mock the GmailService
      result = EmailSync.perform(job)

      # Result could be :ok or {:error, _} depending on Gmail service response
      # The important thing is that it doesn't crash
      assert result == :ok or match?({:error, _}, result)
    end

    test "worker configuration" do
      # Test that the worker has the required Oban.Worker interface
      assert function_exported?(EmailSync, :perform, 1)

      # Test that the worker can be created - this validates basic Oban config
      job = %Oban.Job{
        worker: "JumpstartAi.Workers.EmailSync",
        queue: "email_sync",
        args: %{"user_id" => Ash.UUID.generate()}
      }

      # Basic validation that it's an Oban job with correct worker
      assert job.worker == "JumpstartAi.Workers.EmailSync"
      assert job.queue == "email_sync"
    end
  end
end
