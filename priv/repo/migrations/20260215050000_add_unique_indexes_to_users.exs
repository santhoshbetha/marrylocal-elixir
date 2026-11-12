defmodule Marrylocal.Repo.Migrations.AddUniqueIndexesToUsers do
  use Ecto.Migration

  @moduledoc """
  Indexes for the profile/search columns.

  Written as `IF NOT EXISTS` so a fresh database can replay the full migration
  chain even though the auth migration already owns `users_email_index`.
  """

  def change do
    execute "CREATE INDEX IF NOT EXISTS users_shortlist_index ON users USING GIN (shortlist)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_shortid_index ON users (shortid)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_referral_code_index ON users (referral_code)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_phone_number_index ON users (phone_number)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_email_index ON users (email)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_aadhar_number_index ON users (aadhar_number)"

    execute "CREATE INDEX IF NOT EXISTS users_city_gender_user_state_index ON users (city, gender, user_state)"

    execute "CREATE INDEX IF NOT EXISTS users_geo_index ON users USING GIST ((ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography))"

    execute "CREATE INDEX IF NOT EXISTS users_date_of_creation_index ON users ((date_of_creation::date))"
  end
end
