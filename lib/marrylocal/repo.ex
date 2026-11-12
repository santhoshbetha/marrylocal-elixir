defmodule Marrylocal.Repo do
  use Ecto.Repo,
    otp_app: :marrylocal,
    adapter: Ecto.Adapters.Postgres

  use Scrivener,
    # Default items per page
    page_size: 20
end
