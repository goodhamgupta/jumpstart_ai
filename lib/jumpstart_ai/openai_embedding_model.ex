defmodule JumpstartAi.OpenAiEmbeddingModel do
  @moduledoc """
  OpenAI embedding model implementation for AshAi.
  Uses text-embedding-3-small for cost-effective, high-quality embeddings.
  """

  use AshAi.EmbeddingModel

  require Logger

  @impl true
  # text-embedding-3-small dimensions
  def dimensions(_opts), do: 1536

  @impl true
  def generate(texts, opts) do
    Logger.info("AshAi generate called with texts: #{inspect(texts)}, opts: #{inspect(opts)}")

    # OpenAI API expects individual strings, not arrays
    # If we get a list, process each text separately
    texts_list = if is_list(texts), do: texts, else: [texts]

    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, "OPENAI_API_KEY environment variable is not set"}
    else
      # Process each text individually
      results =
        Enum.map(texts_list, fn text ->
          generate_single_embedding(text, api_key)
        end)

      # Check if all succeeded
      case Enum.find(results, fn {status, _} -> status == :error end) do
        nil ->
          embeddings = Enum.map(results, fn {:ok, embedding} -> embedding end)
          {:ok, embeddings}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp generate_single_embedding(text, api_key) do
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    # OpenAI expects a single string, not an array
    body = %{
      "input" => text,
      "model" => "text-embedding-3-small"
    }

    Logger.info("Sending request to OpenAI with body: #{inspect(body)}")

    case HTTPoison.post("https://api.openai.com/v1/embeddings", Jason.encode!(body), headers,
           timeout: 30_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"data" => [%{"embedding" => embedding}]}} ->
            {:ok, embedding}

          {:error, decode_error} ->
            Logger.error("Failed to decode OpenAI embedding response: #{inspect(decode_error)}")
            {:error, "Failed to decode embedding response"}
        end

      {:ok, %HTTPoison.Response{status_code: status_code, body: body}} ->
        Logger.error("OpenAI API error #{status_code}: #{body}")
        {:error, "OpenAI API error #{status_code}: #{body}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
