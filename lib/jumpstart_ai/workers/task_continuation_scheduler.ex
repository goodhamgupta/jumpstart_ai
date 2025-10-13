defmodule JumpstartAi.Workers.TaskContinuationScheduler do
  @moduledoc """
  Scheduler for task continuation jobs. This is used by AshOban to schedule
  TaskContinuation workers for tasks that are waiting for responses.
  """
  use Oban.Worker, queue: :schedulers, max_attempts: 3

  require Logger
  require Ash.Query
  
  alias JumpstartAi.Workers.TaskContinuation

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("TaskContinuationScheduler - Checking for tasks waiting for response")

    # Query all tasks that are waiting for response
    tasks = get_waiting_tasks()
    task_count = length(tasks)

    if task_count > 0 do
      Logger.info("TaskContinuationScheduler - Found #{task_count} tasks waiting for response")
      
      # Enqueue continuation jobs for each task
      Enum.each(tasks, fn task ->
        case TaskContinuation.new(%{id: task.id}) |> Oban.insert() do
          {:ok, _job} ->
            Logger.debug("TaskContinuationScheduler - Enqueued continuation for task #{task.id}")

          {:error, error} ->
            Logger.error(
              "TaskContinuationScheduler - Failed to enqueue continuation for task #{task.id}: #{inspect(error)}"
            )
        end
      end)
    else
      Logger.debug("TaskContinuationScheduler - No tasks waiting for response")
    end

    :ok
  end

  defp get_waiting_tasks do
    import Ash.Expr
    
    JumpstartAi.Chat.Task
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(expr(status == :waiting_for_response))
    |> Ash.read!(authorize?: false)
  rescue
    error ->
      Logger.error("TaskContinuationScheduler - Failed to query waiting tasks: #{inspect(error)}")
      []
  end
end