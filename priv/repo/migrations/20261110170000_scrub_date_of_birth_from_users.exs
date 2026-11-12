defmodule Marrylocal.Repo.Migrations.ScrubDateOfBirthFromUsers do
  use Ecto.Migration

  @moduledoc """
  Privacy backfill. Legacy raw birthdays are removed from existing rows; age
  remains the only persisted birthday-derived value.
  """

  def up do
    execute "UPDATE users SET date_of_birth = NULL WHERE date_of_birth IS NOT NULL"
  end

  def down do
    :ok
  end
end
