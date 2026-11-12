defmodule Marrylocal.Repo.Migrations.EnablePostgis do
  use Ecto.Migration

  @moduledoc """
  Enables PostGIS before any geography column or GIST expression index is
  created. This migration runs before the profile index migration and is
  idempotent for environments where PostGIS was enabled out-of-band.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"
  end

  def down do
    # Never drop PostGIS automatically; other schemas may depend on it.
    :ok
  end
end
