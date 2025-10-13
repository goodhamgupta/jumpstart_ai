defmodule JumpstartAi.Workers.TaskContinuation do
  use Oban.Worker, queue: :task_continuation

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id, "trigger" => trigger}}) do
    case JumpstartAi.Chat.Task |> Ash.get(task_id) do
      {:ok, task} ->
        continue_task_conversation(task, trigger)

      {:error, reason} ->
        Logger.error("Failed to fetch task #{task_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp continue_task_conversation(task, trigger) do
    # Prompt AI to continue the task based on new information
    prompt = """
    You have an active task: #{task.description}
    
    Current context: #{inspect(task.context)}
    Next action planned: #{task.next_action}
    
    New trigger: #{trigger}
    
    Continue working on this task. Use your tools to move it forward.
    """

    # Create a new message in the conversation to continue the task
    case JumpstartAi.Chat.create_message(%{
           content: prompt,
           source: :system,
           conversation_id: task.conversation_id,
           actor: task.user
         }) do
      {:ok, _message} ->
        Logger.info("Task continuation triggered for task #{task.id}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to create continuation message for task #{task.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end