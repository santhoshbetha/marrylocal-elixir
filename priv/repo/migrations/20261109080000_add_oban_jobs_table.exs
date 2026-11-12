defmodule Marrylocal.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    # Generates oban_jobs, oban_peers, and the specialized notification index
    # structures atomically, before matchmaking/profile migrations run.
    Oban.Migration.up(version: 12)
  end

  def down do
    # Gracefully rolls the Oban schema back through its supported versions.
    Oban.Migration.down(version: 1)
  end
end
