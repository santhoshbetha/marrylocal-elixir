defmodule Marrylocal.Release do
  @moduledoc """
  Release-time tasks for the compiled OTP application.

  These functions are invoked with `bin/marrylocal eval`, for example:

      bin/marrylocal eval "Marrylocal.Release.migrate()"
      bin/marrylocal eval "Marrylocal.Release.seed()"

  `seed/0` is intentionally scoped to deterministic `.test` accounts. It never
  deletes non-test users or production data.
  """

  @app :marrylocal

  @doc """
  Runs every pending migration against each configured Ecto repository.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  @doc """
  Rolls a repository back to the given migration version.
  """
  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, :down, to: version)
      end)
  end

  @doc """
  Loads the deterministic Indian matchmaking test dataset.

  The seed script removes prior accounts whose email ends in `.test`, then
  inserts 30 verified profiles across Mumbai, Bangalore, Hyderabad, and Delhi.
  It is safe to run repeatedly.
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Code.eval_file(Application.app_dir(:marrylocal, "priv/repo/seeds.exs"))
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(@app)
  end
end
