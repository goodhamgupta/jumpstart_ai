defmodule JumpstartAi.Workers.EmailMarkdownWorker do
  @moduledoc """
  Background worker for generating markdown content from email bodies using LLM.

  This worker processes emails in batches to optimize API usage and avoid
  overwhelming the OpenAI API. It prioritizes content sources in the following order:
  1. body_text (plain text)
  2. body_html (HTML content)
  3. snippet (email preview)

  The worker handles:
  - Batch processing of multiple emails
  - Error handling and retry logic
  - Updating email records with generated markdown content
  - Skipping emails that already have markdown content
  """
  use Oban.Worker, queue: :email_to_markdown, max_attempts: 3

  require Logger
  require Ash.Query
  alias JumpstartAi.Accounts.Email

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email_ids" => email_ids}}) when is_list(email_ids) do
    Logger.info(
      "EmailMarkdownWorker - Processing #{length(email_ids)} emails for markdown generation"
    )

    # Fetch emails that need markdown generation
    emails = get_emails_for_processing(email_ids)

    if length(emails) > 0 do
      Logger.info(
        "EmailMarkdownWorker - Found #{length(emails)} emails needing markdown generation"
      )

      process_emails_batch(emails)
    else
      Logger.info("EmailMarkdownWorker - No emails found needing markdown generation")
      :ok
    end
  end

  def perform(%Oban.Job{args: %{"email_id" => email_id}}) do
    Logger.info(
      "EmailMarkdownWorker - Processing single email #{email_id} for markdown generation"
    )

    case Email |> Ash.get(email_id, authorize?: false) do
      {:ok, email} ->
        if should_generate_markdown?(email) do
          process_single_email(email)
        else
          Logger.info(
            "EmailMarkdownWorker - Email #{email_id} already has markdown content or no content to process"
          )

          :ok
        end

      {:error, error} ->
        Logger.error("EmailMarkdownWorker - Failed to fetch email #{email_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("EmailMarkdownWorker - Invalid job arguments: #{inspect(args)}")
    {:error, "Invalid job arguments"}
  end

  defp get_emails_for_processing(email_ids) do
    Email
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^email_ids)
    |> Ash.Query.select([
      :id,
      :subject,
      :body_text,
      :body_html,
      :snippet,
      :markdown_content,
      :user_id
    ])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&should_generate_markdown?/1)
  end

  defp should_generate_markdown?(email) do
    # Generate markdown if:
    # 1. Email doesn't already have markdown content
    # 2. Email has at least one content source (body_text, body_html, or snippet)
    is_nil(email.markdown_content) and has_content?(email)
  end

  defp has_content?(email) do
    has_body_text = is_binary(email.body_text) and String.trim(email.body_text) != ""
    has_body_html = is_binary(email.body_html) and String.trim(email.body_html) != ""
    has_snippet = is_binary(email.snippet) and String.trim(email.snippet) != ""

    has_body_text || has_body_html || has_snippet
  end

  defp process_emails_batch(emails) do
    Logger.info("EmailMarkdownWorker - Processing batch of #{length(emails)} emails in parallel")

    # Process emails in parallel using Task.async_stream
    # Set max_concurrency to balance speed vs API rate limits
    max_concurrency = min(length(emails), 10)

    results =
      emails
      |> Task.async_stream(&process_single_email/1,
        max_concurrency: max_concurrency,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          Logger.error("EmailMarkdownWorker - Task exited with reason: #{inspect(reason)}")
          {:error, reason}
      end)

    successful_count = Enum.count(results, fn result -> result == :ok end)
    failed_count = length(results) - successful_count

    Logger.info(
      "EmailMarkdownWorker - Parallel batch processing complete: #{successful_count} successful, #{failed_count} failed"
    )

    if failed_count > 0 do
      Logger.warning("EmailMarkdownWorker - Some emails failed to process, but continuing")
    end

    :ok
  end

  defp process_single_email(email) do
    Logger.debug("EmailMarkdownWorker - Processing email #{email.id}")

    try do
      # Generate markdown content using the LLM action
      case generate_markdown_for_email(email) do
        {:ok, markdown_content} ->
          # Update the email with the generated markdown content
          case update_email_with_markdown(email, markdown_content) do
            {:ok, _updated_email} ->
              Logger.debug(
                "EmailMarkdownWorker - Successfully generated markdown for email #{email.id}"
              )

              :ok

            {:error, error} ->
              Logger.error(
                "EmailMarkdownWorker - Failed to update email #{email.id} with markdown: #{inspect(error)}"
              )

              {:error, error}
          end

        {:error, error} ->
          Logger.error(
            "EmailMarkdownWorker - Failed to generate markdown for email #{email.id}: #{inspect(error)}"
          )

          {:error, error}
      end
    rescue
      exception ->
        Logger.error(
          "EmailMarkdownWorker - Exception processing email #{email.id}: #{inspect(exception)}"
        )

        {:error, exception}
    end
  end

  defp generate_markdown_for_email(email) do
    # Get the user who owns this email to use as actor
    case JumpstartAi.Accounts.User |> Ash.get(email.user_id, authorize?: false) do
      {:ok, user} ->
        # Debug: Log what content we're sending to the LLM
        content_summary = %{
          has_body_text: !is_nil(email.body_text) and String.trim(email.body_text) != "",
          has_body_html: !is_nil(email.body_html) and String.trim(email.body_html) != "",
          has_snippet: !is_nil(email.snippet) and String.trim(email.snippet) != "",
          subject_length: if(email.subject, do: String.length(email.subject), else: 0),
          total_content_length: calculate_total_content_length(email)
        }

        Logger.debug(
          "EmailMarkdownWorker - Email #{email.id} content summary: #{inspect(content_summary)}"
        )

        case Email
             |> Ash.ActionInput.for_action(:generate_markdown_content, %{
               body_text: email.body_text,
               body_html: email.body_html,
               snippet: email.snippet,
               subject: email.subject
             })
             |> Ash.run_action(actor: user, authorize?: false) do
          {:ok, %LangChain.Chains.LLMChain{} = chain} ->
            # Extract the actual result from the chain
            case chain.last_message do
              %{content: content} when is_binary(content) ->
                {:ok, content}

              %{content: nil, status: :length} ->
                Logger.warning(
                  "EmailMarkdownWorker - Response truncated for email #{email.id}, using partial result"
                )

                # Try to get content from previous messages or return a fallback
                fallback_content = get_fallback_content(email)
                {:ok, fallback_content}

              _ ->
                Logger.error(
                  "EmailMarkdownWorker - No valid content in LLM response for email #{email.id}"
                )

                {:error, "No valid content in LLM response"}
            end

          {:ok, result} when is_binary(result) ->
            {:ok, result}

          {:ok, nil} ->
            Logger.warning(
              "EmailMarkdownWorker - LLM returned nil for email #{email.id}, using fallback content"
            )

            fallback_content = get_fallback_content(email)
            {:ok, fallback_content}

          {:error, error} ->
            {:error, error}

          other ->
            Logger.error(
              "EmailMarkdownWorker - Unexpected response format for email #{email.id}: #{inspect(other)}"
            )

            fallback_content = get_fallback_content(email)
            {:ok, fallback_content}
        end

      {:error, error} ->
        Logger.error(
          "EmailMarkdownWorker - Failed to get user #{email.user_id} for email #{email.id}: #{inspect(error)}"
        )

        {:error, "Failed to get user for authorization"}
    end
  end

  defp calculate_total_content_length(email) do
    [email.body_text, email.body_html, email.snippet, email.subject]
    |> Enum.map(fn content ->
      if is_binary(content), do: String.length(content), else: 0
    end)
    |> Enum.sum()
  end

  defp get_fallback_content(email) do
    cond do
      is_binary(email.snippet) and String.trim(email.snippet) != "" ->
        "**#{email.subject || "No Subject"}**\n\n#{String.trim(email.snippet)}"

      is_binary(email.body_text) and String.length(email.body_text) < 500 ->
        "**#{email.subject || "No Subject"}**\n\n#{String.trim(email.body_text)}"

      true ->
        "**#{email.subject || "No Subject"}**\n\n[Content too long to process]"
    end
  end

  defp update_email_with_markdown(email, markdown_content) do
    # Update email with markdown content - this will automatically trigger vectorization
    # via the after_action change in the :update action
    email
    |> Ash.Changeset.for_update(:update, %{markdown_content: markdown_content})
    |> Ash.update(authorize?: false)
  end

  # Helper function to enqueue jobs from other parts of the application
  def enqueue_single_email(email_id) when is_binary(email_id) do
    %{email_id: email_id}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  def enqueue_batch_emails(email_ids) when is_list(email_ids) and length(email_ids) > 0 do
    %{email_ids: email_ids}
    |> __MODULE__.new()
    |> Oban.insert()
  end

  def enqueue_batch_emails([]), do: {:ok, nil}
end
