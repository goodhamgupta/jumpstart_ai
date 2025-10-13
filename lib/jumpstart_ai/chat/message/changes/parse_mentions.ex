defmodule JumpstartAi.Chat.Message.Changes.ParseMentions do
  use Ash.Resource.Change

  def change(changeset, _, _) do
    case Ash.Changeset.get_attribute(changeset, :text) do
      nil ->
        changeset

      text ->
        mentions = parse_mentions_from_text(text)
        Ash.Changeset.change_attribute(changeset, :mentions, mentions)
    end
  end

  defp parse_mentions_from_text(text) do
    # Pattern to match @[Name](contact_id)
    ~r/@\[([^\]]+)\]\(([^)]+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_full_match, name, id] ->
      %{
        "name" => name,
        "contact_id" => id,
        "type" => "contact"
      }
    end)
  end
end
