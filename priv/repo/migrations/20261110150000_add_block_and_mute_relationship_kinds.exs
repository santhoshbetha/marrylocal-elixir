defmodule Marrylocal.Repo.Migrations.AddBlockAndMuteRelationshipKinds do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE relationships DROP CONSTRAINT IF EXISTS relationships_kind_check"

    execute """
    ALTER TABLE relationships
    ADD CONSTRAINT relationships_kind_check
    CHECK (kind IN ('like', 'dislike', 'shortlist', 'match', 'mute', 'block'))
    """
  end

  def down do
    execute "ALTER TABLE relationships DROP CONSTRAINT IF EXISTS relationships_kind_check"

    execute """
    ALTER TABLE relationships
    ADD CONSTRAINT relationships_kind_check
    CHECK (kind IN ('like', 'dislike', 'shortlist', 'match'))
    """
  end
end
