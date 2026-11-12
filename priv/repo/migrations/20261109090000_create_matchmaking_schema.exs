defmodule Marrylocal.Repo.Migrations.CreateMatchmakingSchema do
  use Ecto.Migration

  @doc """
  Adds the PostGIS-backed discovery fields and the two polymorphic tables the
  MarryLocal backend owns after leaving Supabase.

  Existing users keep their bigint primary keys. Only the discovery surface is
  new, so this migration is additive and can be rolled back without touching
  authentication or subscription rows.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"

    alter table(:users) do
      add :user_handle, :string
      add :caste, :string
    end

    # A native geography column, not a pair of floats. PostGIS stores the
    # lon/lat order internally and every distance query is geodesic.
    execute "ALTER TABLE users ADD COLUMN location geography(Point, 4326)"

    execute """
    UPDATE users
    SET location = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
    WHERE longitude IS NOT NULL AND latitude IS NOT NULL
    """

    # Case-insensitive handles, like the MeetCutes nickname index. Multiple
    # legacy rows may have no handle yet, so the index is partial.
    execute """
    CREATE UNIQUE INDEX users_user_handle_lower_index
    ON users (lower(user_handle))
    WHERE user_handle IS NOT NULL
    """

    execute "CREATE INDEX users_location_gix ON users USING GIST (location)"

    create table(:relationships) do
      add :actor_id, references(:users, on_delete: :delete_all), null: false
      add :target_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:relationships, [:actor_id, :target_id, :kind])
    create index(:relationships, [:actor_id, :kind])
    create index(:relationships, [:target_id, :kind])

    create constraint(:relationships, :relationships_kind_check,
             check: "kind IN ('like', 'dislike', 'shortlist', 'match')"
           )

    create constraint(:relationships, :relationships_no_self_check,
             check: "actor_id <> target_id"
           )

    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :type, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :is_read, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:user_id, :is_read])
    create index(:notifications, [:user_id, :inserted_at])

    create constraint(:notifications, :notifications_type_check,
             check:
               "type IN ('profile_like', 'mutual_match', 'profile_shortlist', 'system', 'admin_broadcast')"
           )
  end

  def down do
    drop table(:notifications)
    drop table(:relationships)

    execute "DROP INDEX IF EXISTS users_location_gix"
    execute "DROP INDEX IF EXISTS users_user_handle_lower_index"
    execute "ALTER TABLE users DROP COLUMN IF EXISTS location"

    alter table(:users) do
      remove :caste
      remove :user_handle
    end
  end
end
