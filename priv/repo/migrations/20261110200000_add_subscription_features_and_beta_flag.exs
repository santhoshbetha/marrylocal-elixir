defmodule Marrylocal.Repo.Migrations.AddSubscriptionFeaturesAndBetaFlag do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_beta_tester, :boolean, null: false, default: false
      add :community_search_active, :boolean, null: false, default: false
      add :multi_location_slots, :map, null: false, default: %{}
    end
  end
end
