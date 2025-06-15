defmodule JumpstartAi.GoogleContactsClient do
  @moduledoc """
  Client for interacting with Google People API (Contacts) using stored OAuth tokens
  """

  require Logger

  @people_api_base_url "https://people.googleapis.com/v1"

  @doc """
  Fetches all contacts for a user using their stored OAuth token
  """
  def fetch_contacts(user, opts \\ []) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_people_request(access_token, "/people/me/connections", opts) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches a specific contact by resource name
  """
  def fetch_contact(user, resource_name) do
    with {:ok, access_token} <- get_valid_access_token(user),
         {:ok, response} <- make_people_request(access_token, "/#{resource_name}") do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp token_expired?(user) do
    case user.google_token_expires_at do
      nil -> false
      expires_at -> DateTime.compare(DateTime.utc_now(), expires_at) == :gt
    end
  end

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

  defp make_people_request(access_token, path, params \\ []) do
    url = @people_api_base_url <> path
    headers = [{"Authorization", "Bearer #{access_token}"}]

    # Add required personFields parameter for connections endpoint
    default_params =
      if String.contains?(path, "/connections") do
        [personFields: "names,emailAddresses,phoneNumbers,organizations,metadata"]
      else
        []
      end

    all_params = Keyword.merge(default_params, params)

    url_with_params =
      case all_params do
        [] -> url
        _ -> url <> "?" <> URI.encode_query(all_params)
      end

    case HTTPoison.get(url_with_params, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to decode People API response"}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, "Unauthorized - token may be invalid"}

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("People API request failed with status #{status_code}: #{body}")
        {:error, "People API request failed"}

      {:error, reason} ->
        Logger.error("People API request failed: #{inspect(reason)}")
        {:error, "People API request failed"}
    end
  end
end
