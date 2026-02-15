defmodule Marrylocal.Repo do
  use Ecto.Repo,
    otp_app: :marrylocal,
    adapter: Ecto.Adapters.Postgres
  use Scrivener,
    page_size: 20 # Default items per page

end
