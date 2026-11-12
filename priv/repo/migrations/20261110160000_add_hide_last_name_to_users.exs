defmodule Marrylocal.Repo.Migrations.AddHideLastNameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :hide_last_name, :boolean, null: false, default: true
    end
  end
end
