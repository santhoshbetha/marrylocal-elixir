defmodule Marrylocal.Release do
  @moduledoc """
  Release-safe database tasks.

  These functions run inside a compiled OTP release where Mix is unavailable.
  `Ecto.Migrator.with_repo/2` starts the repository, runs the requested
  operation, and shuts the repository down again.

  Usage from the release binary:

      bin/marrylocal eval "Marrylocal.Release.migrate()"
      bin/marrylocal eval "Marrylocal.Release.rollback(Marrylocal.Repo, 20261112150000)"
      bin/marrylocal eval "Marrylocal.Release.seed()"

  `seed/0` is intentionally scoped to deterministic `.test` accounts. It never
  deletes non-test users or production data.
  """

  @app :marrylocal

  @doc """
  Runs every pending migration for every configured Ecto repository.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _repo, _migrated} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          Ecto.Migrator.run(started_repo, :up, all: true)
        end)
    end

    :ok
  end

  @doc """
  Rolls a repository back to the given migration version.

  Pass the version of the last migration that should remain applied:

      Marrylocal.Release.rollback(Marrylocal.Repo, 20261112150000)
  """
  def rollback(repo, version) when is_atom(repo) and is_integer(version) do
    load_app()

    {:ok, _repo, _migrated} =
      Ecto.Migrator.with_repo(repo, fn started_repo ->
        Ecto.Migrator.run(started_repo, :down, to: version)
      end)

    :ok
  end

  @doc """
  Loads the deterministic Indian matchmaking test dataset.

  The seed script removes prior accounts whose email ends in `.test`, then
  inserts demo profiles across Mumbai, Bangalore, Hyderabad, and Delhi. It is
  safe to run repeatedly.
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _repo, _seeded} =
        Ecto.Migrator.with_repo(repo, fn _started_repo ->
          Code.eval_file(Application.app_dir(@app, "priv/repo/seeds.exs"))
        end)
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
