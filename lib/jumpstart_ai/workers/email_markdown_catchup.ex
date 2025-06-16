defmodule JumpstartAi.Workers.EmailMarkdownCatchup do
  @moduledoc """
  One-time worker to generate markdown content for all existing emails in the database
  that don't already have markdown content.

  This worker should be run once to catch up on historical data. After this initial
  run, all new emails will have their markdown generated automatically via the 
  after_action hook in the Email resource.

  Usage:
  ```elixir
  # Queue the catchup job
  JumpstartAi.Workers.EmailMarkdownCatchup.enqueue()

  # Or run immediately for testing
  JumpstartAi.Workers.EmailMarkdownCatchup.run_catchup()
  ```
  """
  use Oban.Worker, queue: :email_to_markdown, max_attempts: 3

  require Logger
  require Ash.Query
  alias JumpstartAi.Accounts.{Email, User}
  alias JumpstartAi.Workers.EmailMarkdownWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "catchup"}}) do
    Logger.info("EmailMarkdownCatchup - Starting catchup for all users")
    run_catchup()
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("EmailMarkdownCatchup - Invalid job arguments: #{inspect(args)}")
    {:error, "Invalid job arguments"}
  end

  @doc """
  Enqueue a catchup job to process all existing emails without markdown content
  """
  def enqueue do
    %{mode: "catchup"}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  @doc """
  Run the catchup process immediately (useful for testing or manual execution)
  """
  def run_catchup do
    Logger.info("EmailMarkdownCatchup - Starting comprehensive email markdown catchup")

    try do
      # Get all users who have emails
      users_with_emails = get_users_with_emails()
      Logger.info("EmailMarkdownCatchup - Found #{length(users_with_emails)} users with emails")

      if length(users_with_emails) == 0 do
        Logger.info("EmailMarkdownCatchup - No users with emails found, nothing to process")
        :ok
      else
        # Process each user's emails
        total_emails_processed =
          users_with_emails
          |> Enum.map(&process_user_emails/1)
          |> Enum.sum()

        Logger.info(
          "EmailMarkdownCatchup - Completed! Queued markdown generation for #{total_emails_processed} emails"
        )

        :ok
      end
    rescue
      exception ->
        Logger.error("EmailMarkdownCatchup - Exception during catchup: #{inspect(exception)}")
        {:error, exception}
    end
  end

  defp get_users_with_emails do
    User
    |> Ash.Query.for_read(:read)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn user ->
      # Only include users who actually have emails
      case Email
           |> Ash.Query.for_read(:read_user, %{user_id: user.id})
           |> Ash.Query.limit(1)
           |> Ash.read(authorize?: false) do
        {:ok, []} -> false
        {:ok, [_email | _]} -> true
        {:error, _} -> false
      end
    end)
  end

  defp process_user_emails(user) do
    Logger.info("EmailMarkdownCatchup - Processing emails for user #{user.id}")

    try do
      # Find emails that need markdown generation for this user
      email_ids_needing_markdown =
        Email
        |> Ash.Query.for_read(:read_user, %{user_id: user.id})
        |> Ash.Query.select([:id, :markdown_content, :body_text, :body_html, :snippet])
        |> Ash.read!(authorize?: false)
        |> Enum.filter(fn email ->
          # Filter emails that don't have markdown content and have some content to process
          is_nil(email.markdown_content) and
            (has_non_empty_content(email.body_text) or
               has_non_empty_content(email.body_html) or
               has_non_empty_content(email.snippet))
        end)
        |> Enum.map(& &1.id)

      email_count = length(email_ids_needing_markdown)

      if email_count > 0 do
        Logger.info(
          "EmailMarkdownCatchup - User #{user.id} has #{email_count} emails needing markdown generation"
        )

        # Queue batch markdown generation
        case EmailMarkdownWorker.enqueue_batch_emails(email_ids_needing_markdown) do
          {:ok, _job} ->
            Logger.info(
              "EmailMarkdownCatchup - Successfully queued batch markdown generation for user #{user.id}"
            )

            email_count

          {:error, error} ->
            Logger.error(
              "EmailMarkdownCatchup - Failed to queue batch markdown generation for user #{user.id}: #{inspect(error)}"
            )

            0
        end
      else
        Logger.info(
          "EmailMarkdownCatchup - User #{user.id} has no emails needing markdown generation"
        )

        0
      end
    rescue
      exception ->
        Logger.error(
          "EmailMarkdownCatchup - Exception processing emails for user #{user.id}: #{inspect(exception)}"
        )

        0
    end
  end

  defp has_non_empty_content(content) when is_binary(content) do
    String.trim(content) != ""
  end

  defp has_non_empty_content(_), do: false
end
