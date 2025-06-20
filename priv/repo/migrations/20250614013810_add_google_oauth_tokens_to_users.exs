defmodule JumpstartAi.Repo.Migrations.AddGoogleOauthTokensToUsers do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  This file was autogenerated with `mix ash_postgres.generate_migrations`
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add :google_access_token, :text
      add :google_refresh_token, :text
      add :google_token_expires_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:users) do
      remove :google_token_expires_at
      remove :google_refresh_token
      remove :google_access_token
    end
  end
end
