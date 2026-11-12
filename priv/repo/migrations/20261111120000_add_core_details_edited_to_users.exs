defmodule Marrylocal.Repo.Migrations.AddCoreDetailsEditedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :core_details_edited, :boolean, null: false, default: false
    end
  end
end
