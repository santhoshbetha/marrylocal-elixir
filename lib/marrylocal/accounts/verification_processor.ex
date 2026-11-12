defmodule Marrylocal.Accounts.VerificationProcessor do
  @moduledoc """
  Pluggable submission-processing boundary.

  Today every new submission goes straight to the admin review queue. A future
  OCR worker can be enabled by replacing the body of `process_submission/1`
  without changing the public API, database shape, or frontend contract.
  """

  alias Marrylocal.Repo
  alias Marrylocal.Accounts.IdentityVerification

  def process_submission(%IdentityVerification{} = verification) do
    # Future update: replace with
    # Marrylocal.Workers.BotOcrScanner.enqueue(verification.id)
    update_status(verification, "pending_admin_review")
  end

  defp update_status(verification, status) do
    verification
    |> Ecto.Changeset.change(status: status)
    |> Repo.update()
  end
end
