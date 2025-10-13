defmodule JumpstartAi.Workers.TaskContinuation do
  @moduledoc """
  Worker that handles task continuation when a task is waiting for response.
  This worker is triggered by the AshOban trigger defined in the Task resource.
  """
  use Oban.Worker, queue: :task_continuation, max_attempts: 3

  require Logger
  alias JumpstartAi.Chat.Task

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => task_id}}) do
    Logger.info("TaskContinuation - Processing task #{task_id}")

    case Task |> Ash.get(task_id, authorize?: false) do
      {:ok, task} ->
        if task.status == :waiting_for_response do
          process_task_continuation(task)
        else
          Logger.info("TaskContinuation - Task #{task_id} is no longer waiting for response")
          :ok
        end

      {:error, error} ->
        Logger.error("TaskContinuation - Failed to fetch task #{task_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp process_task_continuation(task) do
    # Here you would implement the logic to continue the task
    # This could involve checking for new messages, processing AI responses, etc.
    
    Logger.info("TaskContinuation - Processing continuation for task: #{task.description}")
    
    # For now, we'll just log the task context and next action
    if task.context do
      Logger.debug("TaskContinuation - Task context: #{inspect(task.context)}")
    end
    
    if task.next_action do
      Logger.debug("TaskContinuation - Next action: #{task.next_action}")
    end
    
    # TODO: Implement actual task continuation logic here
    # This might involve:
    # - Checking for new user responses
    # - Processing AI-generated next steps
    # - Updating task status
    # - Creating new messages in the conversation
    
    :ok
  end
end