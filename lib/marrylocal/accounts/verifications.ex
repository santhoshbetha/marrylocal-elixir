defmodule Marrylocal.Accounts.Verifications do
  @moduledoc """
  Identity-verification lifecycle.

  Submission, admin approval, and rejection are transactional. Raw document
  objects are removed from R2 immediately after a decision is committed.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Accounts.SignupGuard
  alias Marrylocal.Accounts.User
  alias Marrylocal.Accounts.VerificationProcessor
  alias Marrylocal.Notifications
  alias Marrylocal.Repo
  alias Marrylocal.Uploaders.VerificationDocument
  alias Marrylocal.Workers.DuplicateAccountPurgeWorker

  @pending_status "pending_admin_review"

  @doc """
  Creates or replaces the user's verification submission inside one transaction.
  """
  def submit(%User{} = user, attrs) do
    attrs = normalize_submission_attrs(attrs)
    identity_hash = SignupGuard.identity_hash(attrs["document_type"], attrs["document_number"])

    Repo.transaction(fn ->
      existing = Repo.get_by(IdentityVerification, user_id: user.id)
      claimed = Repo.get_by(IdentityVerification, identity_hash: identity_hash)

      cond do
        existing && existing.status == "verified" ->
          Repo.rollback(:already_verified)

        claimed && claimed.user_id != user.id ->
          Repo.rollback(:duplicate_identity)

        true ->
          verification = existing || %IdentityVerification{user_id: user.id}

          verification
          |> IdentityVerification.changeset(
            Map.merge(attrs, %{
              "identity_hash" => identity_hash,
              "status" => @pending_status
            })
          )
          |> Repo.insert_or_update()
          |> case do
            {:ok, saved} ->
              case VerificationProcessor.process_submission(saved) do
                {:ok, processed} -> processed
                {:error, reason} -> Repo.rollback(reason)
              end

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  defp normalize_submission_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("document_type", nil, fn value ->
      value && value |> to_string() |> String.trim() |> String.downcase()
    end)
    |> Map.update("document_number", nil, fn value ->
      value && SignupGuard.normalize_document_number(value)
    end)
  end

  @doc "Returns all submissions waiting for an administrator decision."
  def list_pending do
    from(v in IdentityVerification,
      where: v.status == ^@pending_status,
      order_by: [asc: v.inserted_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc "Fetches one verification with its owning user preloaded."
  def get(id) do
    IdentityVerification
    |> Repo.get(id)
    |> case do
      nil -> nil
      verification -> Repo.preload(verification, :user)
    end
  end

  @doc "Fetches the current user's verification submission, if any."
  def get_for_user(user_id) do
    IdentityVerification
    |> Repo.get_by(user_id: user_id)
    |> case do
      nil -> nil
      verification -> Repo.preload(verification, :user)
    end
  end

  @doc """
  Approves one verification, flips the matching user trust flag, writes and
  broadcasts a success notification, then purges the raw R2 document.
  """
  def approve(%IdentityVerification{user: %User{} = user} = verification) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated} <-
               verification
               |> Ecto.Changeset.change(status: "verified", rejection_reason: nil)
               |> Repo.update(),
             {:ok, _user} <- mark_user_verified(user, updated.document_type),
             {:ok, notification} <- create_verified_notification(updated.user_id) do
          {updated, notification}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {updated, notification}} ->
        purge_document(verification)
        enqueue_duplicate_purge(updated.user_id)
        Notifications.broadcast_many([notification])
        {:ok, Repo.preload(updated, :user, force: true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_duplicate_purge(user_id) do
    %{user_id: user_id}
    |> DuplicateAccountPurgeWorker.new()
    |> Oban.insert()
  end

  @doc """
  Rejects one verification with a reason, notifies the owner over the socket,
  and removes the raw document object from R2.
  """
  def reject(%IdentityVerification{user: %User{} = _user} = verification, reason)
      when is_binary(reason) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated} <-
               verification
               |> Ecto.Changeset.change(status: "rejected", rejection_reason: reason)
               |> Repo.update(),
             {:ok, notification} <- create_rejected_notification(updated.user_id, reason) do
          {updated, notification}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {updated, notification}} ->
        purge_document(verification)
        Notifications.broadcast_many([notification])
        {:ok, Repo.preload(updated, :user, force: true)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reject(_verification, _reason), do: {:error, :rejection_reason_required}

  defp mark_user_verified(%User{} = user, document_type) do
    case verification_flag(document_type) do
      nil ->
        {:error, :invalid_document_type}

      field ->
        user
        |> Ecto.Changeset.change(%{field => true})
        |> Repo.update()
    end
  end

  defp verification_flag("aadhaar"), do: :aadhar_verified
  defp verification_flag("passport"), do: :passport_verified
  defp verification_flag("license"), do: :license_verified
  defp verification_flag(_type), do: nil

  defp create_verified_notification(user_id) do
    Notifications.insert_notification(%{
      user_id: user_id,
      type: :system,
      title: "Identity verified",
      body: "Your identity document has been verified. Your profile now carries a trust badge."
    })
  end

  defp create_rejected_notification(user_id, reason) do
    Notifications.insert_notification(%{
      user_id: user_id,
      type: :system,
      title: "Identity verification needs attention",
      body: reason
    })
  end

  defp purge_document(%IdentityVerification{document_image: path}) do
    case VerificationDocument.delete_object(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not purge identity document #{path}: #{inspect(reason)}")
        :ok
    end
  end
end
