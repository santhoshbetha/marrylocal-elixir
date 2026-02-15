defmodule Marrylocal.Repo.Migrations.AddUniqueIndexesToUsers do
  use Ecto.Migration

  def change do
    # Speeds up "NOT IN" queries on the shortlist array
    create index(:users, [:shortlist], using: :gin)

    # Ensure shortid lookups are instant
    create unique_index(:users, [:shortid])
    create unique_index(:users, [:referral_code])
    create unique_index(:users, [:phone_number])
    create unique_index(:users, [:email])
    create unique_index(:users, [:aadhar_number])
    create index(:users, [:city, :gender, :user_state])
    # In a migration
    execute "CREATE INDEX users_geo_index ON users USING GIST (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography);"
    create index(:users, ["(date_of_creation::date)"])
  end
end
