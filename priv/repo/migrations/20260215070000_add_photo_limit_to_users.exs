defmodule Marrylocal.Repo.Migrations.AddPhotoLimitToUsers do
  use Ecto.Migration

  def change do
    create constraint(:users, :images_limit, check: "cardinality(images) <= 10")
    create unique_index(:users, [:email])
    create unique_index(:users, [:phone_number])
  end
end
