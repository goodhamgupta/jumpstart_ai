defmodule JumpstartAi.GmailClient do
  @moduledoc """
  Client for interacting with the Gmail API using OAuth 2.0 authentication.

  This module provides functions to interact with Gmail API endpoints including:
  - Fetching emails and email metadata
  - Managing Gmail labels
  - Creating and sending email drafts
  - Sending emails directly

  ## Authentication

  All functions require a user struct with valid Google OAuth tokens. The module
  automatically handles token refresh when tokens expire using the stored refresh token.

  ## Error Handling

  All public functions return tuples in the form:
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  Common error reasons include:
  - `"No Google access token found for user"` - User hasn't authenticated with Google
  - `"No refresh token available"` - Cannot refresh expired token
  - `"Unauthorized - token may be invalid"` - Token is invalid or revoked
  - `"Gmail API request failed"` - Network or API errors

  ## Examples

      # Fetch recent emails with query parameters
      {:ok, emails} = GmailClient.fetch_emails(user, maxResults: 10, q: "is:unread")

      # Send an email
      email_data = %{
        to: "recipient@example.com",
        subject: "Hello",
        body: "Email content here"
      }
      {:ok, response} = GmailClient.send_email(user, email_data)

  """

  require Logger

  @gmail_api_base_url "https://www.googleapis.com/gmail/v1"

  @type user :: %JumpstartAi.Accounts.User{}
  @type email_data :: %{
          optional(:to) => String.t(),
          optional(:from) => String.t(),
          optional(:cc) => String.t(),
          optional(:bcc) => String.t(),
          optional(:subject) => String.t(),
          optional(:body) => String.t()
        }
  @type api_response :: {:ok, map()} | {:error, String.t()}

  @doc """
  Fetches emails for a user with optional query parameters.

  Retrieves a list of messages from the user's mailbox. By default, returns
  message IDs and thread IDs. Use `fetch_email/2` to get full message details.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `opts` - Keyword list of Gmail API query parameters (optional)

  ## Options

  - `:maxResults` (integer) - Maximum number of messages to return (default: 100, max: 500)
  - `:q` (string) - Gmail search query (e.g., "is:unread", "from:example@email.com")
  - `:labelIds` (list) - Only return messages with labels that match all of the specified label IDs
  - `:pageToken` (string) - Token for pagination to retrieve the next page of results
  - `:includeSpamTrash` (boolean) - Include messages from SPAM and TRASH (default: false)

  ## Returns

  - `{:ok, response}` - Map containing:
    - `"messages"` - List of message objects with `"id"` and `"threadId"`
    - `"nextPageToken"` - Token for next page (if more results available)
    - `"resultSizeEstimate"` - Estimated total number of results
  - `{:error, reason}` - Error string describing what went wrong

  ## Examples

      # Get 10 most recent unread emails
      {:ok, response} = GmailClient.fetch_emails(user, maxResults: 10, q: "is:unread")

      # Get emails from specific sender
      {:ok, response} = GmailClient.fetch_emails(user, q: "from:client@example.com")

      # Paginate through results
      {:ok, page1} = GmailClient.fetch_emails(user, maxResults: 50)
      {:ok, page2} = GmailClient.fetch_emails(user, pageToken: page1["nextPageToken"])

  ## See Also

  - `fetch_email/2` - Fetch full details for a specific message
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.messages/list

  """
  @spec fetch_emails(user(), keyword()) :: api_response()
  def fetch_emails(user, opts \\ []) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_gmail_request(access_token, "/users/me/messages", opts) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches the full details of a specific email by its message ID.

  Returns complete message data including headers, body parts, and metadata.
  The message body may be in multiple parts and will need to be parsed based
  on the MIME type.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `message_id` - The Gmail message ID to fetch

  ## Returns

  - `{:ok, message}` - Map containing complete message data:
    - `"id"` - The message ID
    - `"threadId"` - Thread this message belongs to
    - `"labelIds"` - List of label IDs applied to this message
    - `"snippet"` - Short excerpt of the message text
    - `"payload"` - Message parts including headers and body
    - `"sizeEstimate"` - Estimated size in bytes
    - `"historyId"` - History identifier
    - `"internalDate"` - Internal message creation timestamp
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Get message details
      {:ok, messages} = GmailClient.fetch_emails(user, maxResults: 1)
      message_id = List.first(messages["messages"])["id"]
      {:ok, full_message} = GmailClient.fetch_email(user, message_id)

      # Access message subject
      headers = full_message["payload"]["headers"]
      subject = Enum.find_value(headers, fn h -> h["name"] == "Subject" && h["value"] end)

  ## See Also

  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.messages/get

  """
  @spec fetch_email(user(), String.t()) :: api_response()
  def fetch_email(user, message_id) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_gmail_request(access_token, "/users/me/messages/#{message_id}") do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all Gmail labels for the authenticated user.

  Returns both system labels (INBOX, SENT, TRASH, etc.) and user-created custom labels.
  Labels are used to categorize and organize messages in Gmail.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens

  ## Returns

  - `{:ok, response}` - Map containing:
    - `"labels"` - List of label objects, each with:
      - `"id"` - Unique label identifier
      - `"name"` - Display name of the label
      - `"type"` - Either "system" or "user"
      - `"messageListVisibility"` - Visibility in message list ("show", "hide")
      - `"labelListVisibility"` - Visibility in label list
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Get all labels
      {:ok, response} = GmailClient.fetch_labels(user)
      labels = response["labels"]

      # Find INBOX label
      inbox = Enum.find(labels, fn l -> l["name"] == "INBOX" end)

      # Get all custom (non-system) labels
      custom_labels = Enum.filter(labels, fn l -> l["type"] == "user" end)

  ## See Also

  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.labels/list

  """
  @spec fetch_labels(user()) :: api_response()
  def fetch_labels(user) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_gmail_request(access_token, "/users/me/labels") do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Retrieves a valid access token for the user, refreshing if necessary.
  #
  # This function checks if:
  # 1. The user has an access token
  # 2. The token is still valid (not expired)
  # 3. If expired, attempts to refresh using the refresh token
  #
  # Returns `{:ok, access_token}` or `{:error, reason}`
  @spec get_valid_access_token(user()) :: {:ok, String.t()} | {:error, String.t()}
  defp get_valid_access_token(user) do
    cond do
      is_nil(user.google_access_token) ->
        {:error, "No Google access token found for user"}

      token_expired?(user) ->
        refresh_access_token(user)

      true ->
        {:ok, user.google_access_token}
    end
  end

  # Checks if the user's Google access token has expired.
  #
  # Returns `true` if the token has expired, `false` otherwise.
  # If no expiration time is set, assumes token is still valid.
  @spec token_expired?(user()) :: boolean()
  defp token_expired?(user) do
    case user.google_token_expires_at do
      nil -> false
      expires_at -> DateTime.compare(DateTime.utc_now(), expires_at) == :gt
    end
  end

  # Refreshes the user's access token using their refresh token.
  #
  # Makes a request to Google's OAuth token endpoint to exchange the refresh token
  # for a new access token. Updates the user record with the new token and expiration.
  #
  # Returns `{:ok, new_access_token}` or `{:error, reason}`
  @spec refresh_access_token(user()) :: {:ok, String.t()} | {:error, String.t()}
  defp refresh_access_token(user) do
    if is_nil(user.google_refresh_token) do
      {:error, "No refresh token available"}
    else
      case refresh_token_request(user.google_refresh_token) do
        {:ok, new_tokens} ->
          case update_user_tokens(user, new_tokens) do
            {:ok, updated_user} -> {:ok, updated_user.google_access_token}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Makes a request to Google's OAuth endpoint to refresh the access token.
  #
  # Uses the user's refresh token to obtain a new access token. The refresh token
  # is a long-lived token that can be used to get new short-lived access tokens
  # without requiring the user to re-authenticate.
  #
  # Returns `{:ok, tokens}` with a map containing:
  # - "access_token" - New access token
  # - "expires_in" - Token lifetime in seconds
  # - "token_type" - Type of token (usually "Bearer")
  #
  # Or `{:error, reason}` if the refresh fails.
  @spec refresh_token_request(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp refresh_token_request(refresh_token) do
    {:ok, client_id} =
      JumpstartAi.Secrets.secret_for(
        [:authentication, :strategies, :google, :client_id],
        JumpstartAi.Accounts.User,
        nil,
        nil
      )

    {:ok, client_secret} =
      JumpstartAi.Secrets.secret_for(
        [:authentication, :strategies, :google, :client_secret],
        JumpstartAi.Accounts.User,
        nil,
        nil
      )

    body = %{
      "client_id" => client_id,
      "client_secret" => client_secret,
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    }

    case HTTPoison.post("https://oauth2.googleapis.com/token", Jason.encode!(body), [
           {"Content-Type", "application/json"}
         ]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, tokens} -> {:ok, tokens}
          {:error, _} -> {:error, "Failed to decode token response"}
        end

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("Token refresh failed with status #{status_code}: #{body}")
        {:error, "Token refresh failed"}

      {:error, reason} ->
        Logger.error("Token refresh request failed: #{inspect(reason)}")
        {:error, "Token refresh request failed"}
    end
  end

  # Updates the user record with new OAuth tokens after a refresh.
  #
  # Calculates the expiration timestamp from the "expires_in" value (seconds)
  # and updates the user's access token and expiration time in the database.
  #
  # Uses Ash.Changeset to create an update operation with authorization bypassed
  # since this is an internal token refresh operation.
  #
  # Returns `{:ok, updated_user}` or `{:error, reason}`
  @spec update_user_tokens(user(), map()) :: {:ok, user()} | {:error, any()}
  defp update_user_tokens(user, new_tokens) do
    expires_at =
      case new_tokens["expires_in"] do
        expires_in when is_integer(expires_in) ->
          DateTime.utc_now() |> DateTime.add(expires_in, :second)

        _ ->
          nil
      end

    user
    |> Ash.Changeset.for_update(
      :update,
      %{
        google_access_token: new_tokens["access_token"],
        google_token_expires_at: expires_at
      },
      authorize?: false
    )
    |> Ash.update()
  end

  @doc """
  Creates a new draft email and saves it to the user's Gmail account.

  The draft is saved but not sent. It can be edited later or sent using `send_draft/2`.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `email_data` - Map containing email fields (see Email Data Format below)

  ## Email Data Format

  - `:to` (required for sending) - Recipient email address
  - `:from` (optional) - Sender email address (defaults to `:to` if not provided)
  - `:cc` (optional) - Carbon copy recipients
  - `:bcc` (optional) - Blind carbon copy recipients
  - `:subject` (optional) - Email subject line
  - `:body` (optional) - Plain text email body

  ## Returns

  - `{:ok, draft}` - Map containing:
    - `"id"` - The draft ID
    - `"message"` - The message object within the draft
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Create a draft email
      email_data = %{
        to: "client@example.com",
        subject: "Follow-up on our meeting",
        body: "Hi, just wanted to follow up on our discussion..."
      }
      {:ok, draft} = GmailClient.draft_email(user, email_data)

      # Create draft with CC and BCC
      email_data = %{
        to: "primary@example.com",
        cc: "manager@example.com",
        bcc: "archive@example.com",
        subject: "Team Update",
        body: "Here's the weekly update..."
      }
      {:ok, draft} = GmailClient.draft_email(user, email_data)

  ## See Also

  - `send_draft/2` - Send a draft that was created
  - `list_drafts/2` - List all drafts
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/create

  """
  @spec draft_email(user(), email_data()) :: api_response()
  def draft_email(user, email_data) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, draft_payload} <- build_draft_payload(email_data),
         {:ok, response} <-
           make_gmail_post_request(access_token, "/users/me/drafts", draft_payload) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends an email directly through Gmail without creating a draft.

  The email is composed and sent immediately. This is useful for transactional
  emails or when you don't need to save a draft first.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `email_data` - Map containing email fields (see Email Data Format below)

  ## Email Data Format

  - `:to` (required) - Recipient email address
  - `:from` (optional) - Sender email address (defaults to `:to` if not provided)
  - `:cc` (optional) - Carbon copy recipients
  - `:bcc` (optional) - Blind carbon copy recipients
  - `:subject` (optional) - Email subject line
  - `:body` (optional) - Plain text email body

  ## Returns

  - `{:ok, message}` - Map containing the sent message with:
    - `"id"` - The sent message ID
    - `"threadId"` - The thread ID the message belongs to
    - `"labelIds"` - Labels applied to the sent message
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Send a simple email
      email_data = %{
        to: "client@example.com",
        subject: "Meeting Confirmation",
        body: "This confirms our meeting tomorrow at 2pm."
      }
      {:ok, sent_message} = GmailClient.send_email(user, email_data)

      # Send email with CC
      email_data = %{
        to: "recipient@example.com",
        cc: "manager@example.com",
        subject: "Project Update",
        body: "The project is on track for completion next week."
      }
      {:ok, sent_message} = GmailClient.send_email(user, email_data)

  ## See Also

  - `draft_email/2` - Create a draft instead of sending immediately
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.messages/send

  """
  @spec send_email(user(), email_data()) :: api_response()
  def send_email(user, email_data) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, message_payload} <- build_message_payload(email_data),
         {:ok, response} <-
           make_gmail_post_request(access_token, "/users/me/messages/send", message_payload) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all draft emails for the user with optional query parameters.

  Returns a list of draft message IDs. Use `get_draft/2` to retrieve the full
  content of a specific draft.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `opts` - Keyword list of Gmail API query parameters (optional)

  ## Options

  - `:maxResults` (integer) - Maximum number of drafts to return (default: 100, max: 500)
  - `:pageToken` (string) - Token for pagination to retrieve the next page of results
  - `:q` (string) - Query to filter drafts (same syntax as Gmail search)

  ## Returns

  - `{:ok, response}` - Map containing:
    - `"drafts"` - List of draft objects with `"id"` and `"message"` (with message ID)
    - `"nextPageToken"` - Token for next page (if more results available)
    - `"resultSizeEstimate"` - Estimated total number of drafts
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # List all drafts
      {:ok, response} = GmailClient.list_drafts(user)
      drafts = response["drafts"]

      # List drafts with pagination
      {:ok, page1} = GmailClient.list_drafts(user, maxResults: 25)
      {:ok, page2} = GmailClient.list_drafts(user, pageToken: page1["nextPageToken"])

  ## See Also

  - `get_draft/2` - Get full details of a specific draft
  - `draft_email/2` - Create a new draft
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/list

  """
  @spec list_drafts(user(), keyword()) :: api_response()
  def list_drafts(user, opts \\ []) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_gmail_request(access_token, "/users/me/drafts", opts) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieves the full details of a specific draft by its draft ID.

  Returns the complete draft including the message content, headers, and metadata.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `draft_id` - The Gmail draft ID to retrieve

  ## Returns

  - `{:ok, draft}` - Map containing:
    - `"id"` - The draft ID
    - `"message"` - Complete message object including:
      - `"id"` - The message ID
      - `"threadId"` - The thread ID
      - `"payload"` - Message headers and body parts
      - `"snippet"` - Preview of message content
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Get draft details
      {:ok, drafts} = GmailClient.list_drafts(user, maxResults: 1)
      draft_id = List.first(drafts["drafts"])["id"]
      {:ok, draft_details} = GmailClient.get_draft(user, draft_id)

      # Access draft subject
      headers = draft_details["message"]["payload"]["headers"]
      subject = Enum.find_value(headers, fn h -> h["name"] == "Subject" && h["value"] end)

  ## See Also

  - `list_drafts/2` - List all drafts
  - `send_draft/2` - Send this draft
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/get

  """
  @spec get_draft(user(), String.t()) :: api_response()
  def get_draft(user, draft_id) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_gmail_request(access_token, "/users/me/drafts/#{draft_id}") do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends an existing draft email by its draft ID.

  Once sent, the draft is removed from the drafts folder and appears in the sent folder.
  The message will be sent exactly as it was saved in the draft.

  ## Parameters

  - `user` - User struct with valid Google OAuth tokens
  - `draft_id` - The Gmail draft ID to send

  ## Returns

  - `{:ok, message}` - Map containing the sent message with:
    - `"id"` - The sent message ID
    - `"threadId"` - The thread ID the message belongs to
    - `"labelIds"` - Labels applied to the sent message (typically includes "SENT")
  - `{:error, reason}` - Error string if the request fails

  ## Examples

      # Create and send a draft
      email_data = %{
        to: "client@example.com",
        subject: "Proposal",
        body: "Please find the attached proposal..."
      }
      {:ok, draft} = GmailClient.draft_email(user, email_data)
      {:ok, sent} = GmailClient.send_draft(user, draft["id"])

      # List drafts and send the first one
      {:ok, drafts_response} = GmailClient.list_drafts(user)
      first_draft_id = List.first(drafts_response["drafts"])["id"]
      {:ok, sent_message} = GmailClient.send_draft(user, first_draft_id)

  ## See Also

  - `draft_email/2` - Create a new draft
  - `get_draft/2` - Review draft before sending
  - `send_email/2` - Send email directly without creating a draft
  - Gmail API Reference: https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/send

  """
  @spec send_draft(user(), String.t()) :: api_response()
  def send_draft(user, draft_id) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <-
           make_gmail_post_request(access_token, "/users/me/drafts/#{draft_id}/send", %{}) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Builds the payload for creating a draft email.
  #
  # Wraps the message payload in a draft-specific structure required by the Gmail API.
  #
  # Returns `{:ok, payload}` or `{:error, reason}`
  @spec build_draft_payload(email_data()) :: {:ok, map()} | {:error, String.t()}
  defp build_draft_payload(email_data) do
    case build_message_payload(email_data) do
      {:ok, message_payload} ->
        {:ok, %{"message" => message_payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Builds the message payload for sending or drafting an email.
  #
  # Constructs a properly formatted email message following RFC 2822 standards,
  # then encodes it in base64url format as required by the Gmail API.
  #
  # The function:
  # 1. Builds email headers (From, To, Cc, Bcc, Subject, Content-Type)
  # 2. Combines headers and body into a raw message
  # 3. Encodes the message in base64url format (Gmail requirement)
  #
  # Returns `{:ok, payload}` with a map containing the "raw" encoded message,
  # or `{:error, reason}` if building fails.
  @spec build_message_payload(email_data()) :: {:ok, map()} | {:error, String.t()}
  defp build_message_payload(email_data) do
    try do
      # Build email headers - Gmail requires From header
      headers = []
      # Add From header (use the authenticated user's email)
      headers = [{"From", email_data[:from] || email_data[:to]} | headers]
      headers = if email_data[:to], do: [{"To", email_data[:to]} | headers], else: headers
      headers = if email_data[:cc], do: [{"Cc", email_data[:cc]} | headers], else: headers
      headers = if email_data[:bcc], do: [{"Bcc", email_data[:bcc]} | headers], else: headers

      headers =
        if email_data[:subject], do: [{"Subject", email_data[:subject]} | headers], else: headers

      headers = [{"Content-Type", "text/plain; charset=utf-8"} | headers]

      # Build the raw email message
      header_string =
        headers
        |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
        |> Enum.join("\r\n")

      body = email_data[:body] || ""
      raw_message = header_string <> "\r\n\r\n" <> body

      # Encode the message in base64url format (Gmail requirement)
      encoded_message =
        raw_message
        |> Base.encode64()
        |> String.replace("+", "-")
        |> String.replace("/", "_")
        |> String.replace("=", "")

      payload = %{
        "raw" => encoded_message
      }

      {:ok, payload}
    rescue
      error ->
        Logger.error("Failed to build email payload: #{inspect(error)}")
        {:error, "Failed to build email payload"}
    end
  end

  # Makes a GET request to the Gmail API.
  #
  # Constructs the full URL from the base Gmail API URL and the provided path,
  # appends query parameters if provided, and includes the OAuth access token
  # in the Authorization header.
  #
  # Handles common HTTP status codes:
  # - 200: Success - decodes and returns the JSON response
  # - 401: Unauthorized - token is invalid or expired
  # - Other: Logs error and returns generic error message
  #
  # ## Parameters
  # - `access_token` - Valid OAuth 2.0 access token
  # - `path` - API endpoint path (e.g., "/users/me/messages")
  # - `params` - Keyword list of query parameters (optional)
  #
  # Returns `{:ok, decoded_response}` or `{:error, reason}`
  @spec make_gmail_request(String.t(), String.t(), keyword()) :: api_response()
  defp make_gmail_request(access_token, path, params \\ []) do
    url = @gmail_api_base_url <> path
    headers = [{"Authorization", "Bearer #{access_token}"}]

    url_with_params =
      case params do
        [] -> url
        _ -> url <> "?" <> URI.encode_query(params)
      end

    case HTTPoison.get(url_with_params, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to decode Gmail API response"}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, "Unauthorized - token may be invalid"}

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("Gmail API request failed with status #{status_code}: #{body}")
        {:error, "Gmail API request failed"}

      {:error, reason} ->
        Logger.error("Gmail API request failed: #{inspect(reason)}")
        {:error, "Gmail API request failed"}
    end
  end

  # Makes a POST request to the Gmail API.
  #
  # Constructs the full URL from the base Gmail API URL and the provided path,
  # encodes the payload as JSON, and includes the OAuth access token and
  # Content-Type header in the request.
  #
  # Handles common HTTP status codes:
  # - 200/201: Success - decodes and returns the JSON response
  # - 401: Unauthorized - token is invalid or expired
  # - Other: Logs error and returns error message with response body
  #
  # ## Parameters
  # - `access_token` - Valid OAuth 2.0 access token
  # - `path` - API endpoint path (e.g., "/users/me/messages/send")
  # - `payload` - Map to be JSON-encoded and sent as request body
  #
  # Returns `{:ok, decoded_response}` or `{:error, reason}`
  @spec make_gmail_post_request(String.t(), String.t(), map()) :: api_response()
  defp make_gmail_post_request(access_token, path, payload) do
    url = @gmail_api_base_url <> path

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.post(url, Jason.encode!(payload), headers) do
      {:ok, %HTTPoison.Response{status_code: status_code, body: body}}
      when status_code in [200, 201] ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to decode Gmail API response"}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, "Unauthorized - token may be invalid"}

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("Gmail API POST request failed with status #{status_code}: #{body}")
        {:error, "Gmail API request failed: #{body}"}

      {:error, reason} ->
        Logger.error("Gmail API POST request failed: #{inspect(reason)}")
        {:error, "Gmail API request failed"}
    end
  end
end
