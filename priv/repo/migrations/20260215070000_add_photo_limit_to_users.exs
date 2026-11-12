defmodule Marrylocal.Repo.Migrations.AddPhotoLimitToUsers do
  use Ecto.Migration

  def change do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'images_limit'
      ) THEN
        ALTER TABLE users ADD CONSTRAINT images_limit CHECK (cardinality(images) <= 10);
      END IF;
    END
    $$;
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_email_index ON users (email)"
    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_phone_number_index ON users (phone_number)"
  end
end
