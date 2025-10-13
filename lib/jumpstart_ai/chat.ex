defmodule JumpstartAi.Chat do
  use Ash.Domain, otp_app: :jumpstart_ai, extensions: [AshPhoenix, AshAi]

  tools do
    tool :create_task, JumpstartAi.Chat.Task, :create do
      description """
      Create a new task to track multi-step processes. Use this when the user requests complex
      operations that will require multiple steps or waiting for external responses.
      Tasks help maintain context and can be continued later when new information becomes available.
      """
    end

    tool :update_task_status, JumpstartAi.Chat.Task, :update_status do
      description """
      Update the status of an existing task. Use this to mark tasks as completed, failed,
      or waiting for response. Also update context and next_action as you progress through the task.
      """
    end

    tool :list_active_tasks, JumpstartAi.Chat.Task, :active_for_current_user do
      description """
      List all active tasks for the current user. Use this to see what tasks are currently
      in progress or waiting for responses.
      """
    end

    tool :create_ongoing_instruction, JumpstartAi.Chat.OngoingInstruction, :create do
      description """
      Create a standing instruction that will trigger automatically when specific conditions are met.
      Use this when the user gives instructions like "When X happens, do Y" or "Always do Z when...".
      These instructions will be monitored and executed proactively.
      """
    end

    tool :list_ongoing_instructions, JumpstartAi.Chat.OngoingInstruction, :active_for_current_user do
      description """
      List all active ongoing instructions for the current user. Use this to see what
      proactive rules are currently in place.
      """
    end
  end

  resources do
    resource JumpstartAi.Chat.Conversation do
      define :create_conversation, action: :create
      define :get_conversation, action: :read, get_by: [:id]
      define :my_conversations
    end

    resource JumpstartAi.Chat.Message do
      define :message_history,
        action: :for_conversation,
        args: [:conversation_id],
        default_options: [query: [sort: [inserted_at: :asc]]]

      define :create_message, action: :create
    end

    resource JumpstartAi.Chat.Task do
      define :create_task, action: :create
      define :update_task_status, action: :update_status
      define :list_active_tasks, action: :active_for_current_user
      define :list_active_tasks_for_conversation, action: :active_for_conversation
    end

    resource JumpstartAi.Chat.OngoingInstruction do
      define :create_ongoing_instruction, action: :create
      define :update_ongoing_instruction, action: :update
      define :list_ongoing_instructions, action: :active_for_current_user
    end
  end
end
