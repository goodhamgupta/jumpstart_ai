defmodule JumpstartAi.Repo.Migrations.AddTasksAndOngoingInstructions do
  use Ecto.Migration

  def change do
    # Create tasks table
    create table(:tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :uuid), null: false
      add :conversation_id, references(:conversations, type: :uuid), null: false
      add :description, :text, null: false
      add :status, :text, null: false, default: "active"
      add :context, :map
      add :next_action, :text
      timestamps()
    end

    # Create ongoing_instructions table
    create table(:ongoing_instructions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v7()")
      add :user_id, references(:users, type: :uuid), null: false
      add :instruction, :text, null: false
      add :trigger_conditions, :map
      add :is_active, :boolean, default: true
      add :last_triggered_at, :utc_datetime_usec
      timestamps()
    end

    # Create indexes
    create index(:tasks, [:user_id, :status])
    create index(:tasks, [:conversation_id, :status])
    create index(:ongoing_instructions, [:user_id, :is_active])
  end
end
