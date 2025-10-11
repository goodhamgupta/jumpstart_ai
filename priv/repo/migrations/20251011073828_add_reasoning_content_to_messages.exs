defmodule JumpstartAi.Repo.Migrations.AddReasoningContentToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :reasoning_content, :text
    end
  end
end
