defmodule Marrylocal.Repo.Migrations.AddLookupPrivacyToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :restrict_lookup_to_200km, :boolean, default: true, null: false
      add :allow_email_search, :boolean, default: false, null: false
      add :allow_phone_search, :boolean, default: false, null: false
      add :allow_handle_search, :boolean, default: true, null: false
    end
  end
end
