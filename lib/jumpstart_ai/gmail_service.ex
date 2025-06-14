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
        email_details = Enum.map(messages, fn message ->
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

    %{
      id: email_data["id"],
      thread_id: email_data["threadId"],
      label_ids: email_data["labelIds"] || [],
      snippet: email_data["snippet"],
      subject: get_header_value(headers, "Subject"),
      from: get_header_value(headers, "From"),
      to: get_header_value(headers, "To"),
      date: get_header_value(headers, "Date"),
      body: extract_body(payload)
    }
  end

  defp get_header_value(headers, name) do
    case Enum.find(headers, fn header -> header["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp extract_body(payload) do
    cond do
      payload["body"] && payload["body"]["data"] ->
        decode_base64(payload["body"]["data"])

      payload["parts"] ->
        payload["parts"]
        |> Enum.find(fn part -> 
          part["mimeType"] == "text/plain" || part["mimeType"] == "text/html"
        end)
        |> case do
          %{"body" => %{"data" => data}} -> decode_base64(data)
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp decode_base64(data) when is_binary(data) do
    try do
      data
      |> String.replace(["-", "_"], ["+", "/"])
      |> Base.decode64!(padding: false)
    rescue
      _ -> nil
    end
  end

  defp decode_base64(_), do: nil
end