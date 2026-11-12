defmodule MarrylocalWeb.ReferralsController do
  @moduledoc """
  Authenticated referral analytics for the invite dashboard.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Accounts

  def summary(conn, _params) do
    summary = Accounts.referral_summary(conn.assigns.current_user.id)

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: summary})
  end
end
