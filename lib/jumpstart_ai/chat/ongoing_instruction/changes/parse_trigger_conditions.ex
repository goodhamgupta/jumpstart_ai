defmodule JumpstartAi.Chat.OngoingInstruction.Changes.ParseTriggerConditions do
  @moduledoc """
  Automatically parses the instruction text and generates structured trigger_conditions
  for the OngoingInstruction resource.

  This change uses AshAI's structured output to convert natural language instructions like:
  "When I receive an email from an unknown sender, create a HubSpot contact"

  Into structured trigger conditions like:
  %{"trigger" => "new_email_from_unknown_sender"}
  """
  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    instruction = Ash.Changeset.get_attribute(changeset, :instruction)
    existing_conditions = Ash.Changeset.get_attribute(changeset, :trigger_conditions)

    # Only parse if instruction is present and trigger_conditions is not already set
    if instruction && is_nil(existing_conditions) do
      Logger.info("ParseTriggerConditions: Parsing instruction: #{instruction}")

      input = Ash.ActionInput.for_action(
        JumpstartAi.Chat.OngoingInstruction,
        :parse_trigger_conditions,
        %{instruction: instruction}
      )

      case Ash.run_action(input) do
        {:ok, trigger_conditions_struct} ->
          # Convert the TypedStruct to a map for storage, filtering out nil values
          trigger_conditions =
            trigger_conditions_struct
            |> Map.from_struct()
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()

          Logger.info(
            "ParseTriggerConditions: Parsed instruction into: #{inspect(trigger_conditions)}"
          )

          Ash.Changeset.force_change_attribute(changeset, :trigger_conditions, trigger_conditions)

        {:error, error} ->
          Logger.error(
            "ParseTriggerConditions: Failed to parse instruction: #{inspect(error)}"
          )

          Ash.Changeset.add_error(
            changeset,
            field: :trigger_conditions,
            message: "Failed to parse trigger conditions from instruction: #{inspect(error)}"
          )
      end
    else
      changeset
    end
  end
end
