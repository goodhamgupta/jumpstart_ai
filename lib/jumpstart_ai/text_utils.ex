defmodule JumpstartAi.TextUtils do
  @moduledoc """
  Shared utilities for text processing, particularly for embedding generation.

  This module provides common text cleaning and truncation functions used across
  multiple resources for consistent text preprocessing before vectorization.
  """

  @doc """
  Cleans text for embedding generation by removing HTML entities and non-ASCII characters.

  ## Examples

      iex> JumpstartAi.TextUtils.clean_text("Hello &amp; world &#39;test&#39;")
      "Hello world test"
      
      iex> JumpstartAi.TextUtils.clean_text(nil)
      ""
  """
  def clean_text(text) when is_binary(text) do
    text
    # Remove HTML entities like &#39;
    |> String.replace(~r/&#\d+;/, " ")
    # Remove named HTML entities like &amp;
    |> String.replace(~r/&[a-zA-Z]+;/, " ")
    # Remove all non-ASCII characters
    |> String.replace(~r/[^\x00-\x7F]/, " ")
    # Normalize all whitespace to single spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def clean_text(nil), do: ""

  @doc """
  Truncates content for embedding generation based on estimated token count.

  Uses a rough estimate of 1 token ≈ 4 characters for English text.
  Truncates at word boundaries when possible to avoid cutting words.

  ## Examples

      iex> JumpstartAi.TextUtils.truncate_for_embedding("short text", 1000)
      "short text"
      
      iex> JumpstartAi.TextUtils.truncate_for_embedding(nil, 1000)
      ""
  """
  def truncate_for_embedding(content, max_tokens) when is_binary(content) do
    # Rough estimate: 1 token ≈ 4 characters for English text
    max_chars = max_tokens * 4

    if String.length(content) > max_chars do
      content
      |> String.slice(0, max_chars)
      |> String.reverse()
      |> String.split(" ", parts: 2)
      |> List.last()
      |> String.reverse()
      |> then(&(&1 <> "..."))
    else
      content
    end
  end

  def truncate_for_embedding(nil, _max_tokens), do: ""

  @doc """
  Combines clean_text and truncate_for_embedding for common use case.

  ## Examples

      iex> JumpstartAi.TextUtils.clean_and_truncate("Hello &amp; world", 10)
      "Hello world"
  """
  def clean_and_truncate(text, max_tokens) do
    text
    |> clean_text()
    |> truncate_for_embedding(max_tokens)
  end
end
