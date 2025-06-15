defmodule JumpstartAi.GmailService do
  @moduledoc """
  Service module for Gmail integration using OAuth tokens
  """

  alias JumpstartAi.GmailClient

  @doc """
  Fetches and processes all emails for a user
  """
  def fetch_user_emails(user, opts \\ []) do
    case GmailClient.fetch_emails(user, opts) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        email_details =
          Enum.map(messages, fn message ->
            case GmailClient.fetch_email(user, message["id"]) do
              {:ok, email_data} -> parse_email_data(email_data)
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, email_details}

      {:ok, _response} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams emails in batches, processing and yielding each batch as it's fetched.
  This allows for processing emails in smaller chunks instead of loading all into memory.
  
  Options:
  - batch_size: Number of emails to fetch per batch (default: 50)
  - max_results: Maximum total emails to fetch (default: 500)
  - process_fn: Function to call with each batch of processed emails
  """
  def stream_user_emails(user, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    max_results = Keyword.get(opts, :max_results, 500)
    process_fn = Keyword.get(opts, :process_fn, fn batch -> {:ok, batch} end)
    
    stream_emails_with_pagination(user, process_fn, batch_size, max_results, nil, 0)
  end
  
  defp stream_emails_with_pagination(user, process_fn, batch_size, max_results, page_token, processed_count) do
    # Calculate how many emails to fetch in this batch
    remaining = max_results - processed_count
    current_batch_size = min(batch_size, remaining)
    
    if current_batch_size <= 0 do
      {:ok, processed_count}
    else
      # Build request options with pagination
      opts = [maxResults: current_batch_size]
      opts = if page_token, do: Keyword.put(opts, :pageToken, page_token), else: opts
      
      case GmailClient.fetch_emails(user, opts) do
        {:ok, %{"messages" => messages, "nextPageToken" => next_token}} when is_list(messages) ->
          case process_batch_of_emails(user, messages, process_fn) do
            {:ok, batch_count} ->
              new_processed_count = processed_count + batch_count
              
              # Continue with next page if we have more to fetch and there's a next page token
              if new_processed_count < max_results and next_token do
                stream_emails_with_pagination(user, process_fn, batch_size, max_results, next_token, new_processed_count)
              else
                {:ok, new_processed_count}
              end
              
            {:error, reason} ->
              {:error, reason}
          end
          
        {:ok, %{"messages" => messages}} when is_list(messages) ->
          # No more pages available
          case process_batch_of_emails(user, messages, process_fn) do
            {:ok, batch_count} ->
              {:ok, processed_count + batch_count}
            {:error, reason} ->
              {:error, reason}
          end
          
        {:ok, _response} ->
          # No messages found
          {:ok, processed_count}
          
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
  
  defp process_batch_of_emails(user, messages, process_fn) do
    email_details =
      messages
      |> Enum.map(fn message ->
        case GmailClient.fetch_email(user, message["id"]) do
          {:ok, email_data} -> parse_email_data(email_data)
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    
    case process_fn.(email_details) do
      {:ok, _result} -> {:ok, length(email_details)}
      {:error, reason} -> {:error, reason}
      :ok -> {:ok, length(email_details)}
    end
  end

  @doc """
  Gets the user's Gmail labels
  """
  def get_user_labels(user) do
    case GmailClient.fetch_labels(user) do
      {:ok, %{"labels" => labels}} -> {:ok, labels}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Searches for emails matching a query
  """
  def search_emails(user, query) do
    case GmailClient.fetch_emails(user, q: query) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_email_data(email_data) do
    payload = email_data["payload"]
    headers = payload["headers"] || []

    {body_text, body_html} = extract_body_content(payload)
    attachments = extract_attachments(payload)

    %{
      id: email_data["id"],
      thread_id: email_data["threadId"],
      label_ids: email_data["labelIds"] || [],
      snippet: email_data["snippet"],
      subject: get_header_value(headers, "Subject"),
      from: get_header_value(headers, "From"),
      to: get_header_value(headers, "To"),
      date: get_header_value(headers, "Date"),
      # Keep for backward compatibility
      body: body_text || body_html,
      body_text: body_text,
      body_html: body_html,
      attachments: attachments,
      mime_type: payload["mimeType"]
    }
  end

  defp get_header_value(headers, name) do
    case Enum.find(headers, fn header -> header["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp extract_body_content(payload) do
    {text_body, html_body} =
      cond do
        payload["body"] && payload["body"]["data"] ->
          # Single part message
          body_content = decode_base64(payload["body"]["data"])

          case payload["mimeType"] do
            "text/html" -> {nil, body_content}
            "text/plain" -> {body_content, nil}
            _ -> {body_content, nil}
          end

        payload["parts"] ->
          # Multi-part message
          extract_multipart_content(payload["parts"])

        true ->
          {nil, nil}
      end

    {text_body, html_body}
  end

  defp extract_multipart_content(parts) do
    text_body = find_body_by_type(parts, "text/plain")
    html_body = find_body_by_type(parts, "text/html")
    {text_body, html_body}
  end

  defp find_body_by_type(parts, mime_type) do
    parts
    |> Enum.find(fn part -> part["mimeType"] == mime_type end)
    |> case do
      %{"body" => %{"data" => data}} -> decode_base64(data)
      %{"parts" => nested_parts} -> find_body_by_type(nested_parts, mime_type)
      _ -> nil
    end
  end

  defp extract_attachments(payload) do
    extract_attachments_from_parts(payload["parts"] || [])
  end

  defp extract_attachments_from_parts(parts) do
    parts
    |> Enum.flat_map(fn part ->
      cond do
        # Check if this part is an attachment
        part["filename"] && part["filename"] != "" ->
          [
            %{
              filename: part["filename"],
              mime_type: part["mimeType"],
              attachment_id: get_in(part, ["body", "attachmentId"]),
              size: get_in(part, ["body", "size"]) || 0,
              headers: part["headers"] || []
            }
          ]

        # Check nested parts for attachments
        part["parts"] ->
          extract_attachments_from_parts(part["parts"])

        true ->
          []
      end
    end)
  end

  defp decode_base64(data) when is_binary(data) do
    try do
      # Gmail uses URL-safe base64 with padding removed
      # Convert URL-safe characters back to standard base64
      data
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      # Add padding if needed
      |> pad_base64()
      |> Base.decode64!()
    rescue
      _ -> nil
    end
  end

  defp decode_base64(_), do: nil

  defp pad_base64(data) do
    # Add padding to make the string length a multiple of 4
    case rem(String.length(data), 4) do
      0 -> data
      1 -> data <> "==="
      2 -> data <> "=="
      3 -> data <> "="
    end
  end
end
