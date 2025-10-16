defmodule JumpstartAi.Chat.OngoingInstruction.Types.TriggerConditions do
  @moduledoc """
  Typed struct for trigger conditions parsed from natural language instructions.
  """
  use Ash.TypedStruct

  typed_struct do
    field :trigger, :string, allow_nil?: false
    field :sender_email, :string
  end
end
