defmodule Marrylocal.Accounts.Verifications do
  @moduledoc """
  Identity-verification lifecycle.

  Submission, admin approval, and rejection are transactional. Raw document
  objects are removed from R2 immediately after a decision is committed.
  """

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts.IdentityVerification
  alias Marrylocal.Accounts.SignupGuard
  alias Marrylocal.Accounts.User
  alias Marrylocal.Accounts.VerificationProcessor
  alias Marrylocal.Notifications
  alias Marrylocal.Repo
  alias Marrylocal.Uploaders.VerificationDocument
  alias Marrylocal.Workers.DeleteR2ObjectWorker
  alias Marrylocal.Workers.DuplicateAccountPurgeWorker

  @pending_status "pending_admin_review"

  @doc """
  Creates or replaces the user's verification submission.

  Waffle uploads the document while `IdentityVerification.changeset/2` is built.
  That changeset is constructed before `Repo.transaction/1` so a slow mobile
  upload never pins a PostgreSQL pool connection. The database phase only does
  the uniqueness checks, insert/update, and status transition.
  """
  def submit(%User{} = user, attrs) do
    attrs = normalize_submission_attrs(attrs)
    identity_hash = SignupGuard.identity_hash(attrs["document_type"], attrs["document_number"])

    case submission_gate(user, identity_hash) do
      :ok ->
        existing = Repo.get_by(IdentityVerification, user_id: user.id)
        verification = existing || %IdentityVerification{user_id: user.id}

        # This line performs the R2 upload via Waffle.Ecto. Keep it outside the
        # transaction so the database is never held during network I/O.
        changeset =
          IdentityVerification.changeset(
            verification,
            Map.merge(attrs, %{
              "identity_hash" => identity_hash,
              "status" => @pending_status
            })
          )

        result =
          Repo.transaction(fn ->
            case Repo.insert_or_update(changeset) do
              {:ok, saved} ->
                case VerificationProcessor.process_submission(saved) do
                  {:ok, processed} -> processed
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
          end)

        case result do
          {:ok, saved} ->
            {:ok, saved}

          {:error, %Ecto.Changeset{} = changeset} ->
            cleanup_uploaded_document(changeset, verification)

            if changeset.errors[:identity_hash] do
              {:error, :duplicate_identity}
            else
              {:error, changeset}
            end

          {:error, reason} ->
            cleanup_uploaded_document(changeset, verification)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submission_gate(user, identity_hash) do
    existing = Repo.get_by(IdentityVerification, user_id: user.id)
    claimed = Repo.get_by(IdentityVerification, identity_hash: identity_hash)

    cond do
      existing && existing.status == "verified" -> {:error, :already_verified}
      claimed && claimed.user_id != user.id -> {:error, :duplicate_identity}
      true -> :ok
    end
  end

  defp cleanup_uploaded_document(%Ecto.Changeset{} = changeset, verification) do
    case Ecto.Changeset.get_change(changeset, :document_image) do
      %{file_name: file_name} when is_binary(file_name) and file_name != "" ->
        key =
          Path.join(
            VerificationDocument.storage_dir(:original, {%{file_name: file_name}, verification}),
            file_name
          )

        %{bucket: VerificationDocument.bucket(), key: String.trim_leading(key, "/")}
        |> DeleteR2ObjectWorker.new()
        |> Oban.insert()

        :ok

      _ ->
        :ok
    end
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
    list(%{})
  end

  @doc "Returns submissions filtered by status and age in hours."
  def list(params \\ %{}) when is_map(params) do
    status = params["status"] || @pending_status
    hours = parse_hours(params["older_than_hours"])

    query =
      from(v in IdentityVerification,
        where: v.status == ^status,
        order_by: [asc: v.inserted_at],
        preload: [:user]
      )

    query =
      if hours do
        cutoff = DateTime.add(DateTime.utc_now(), -hours, :hour)
        from(v in query, where: v.inserted_at <= ^cutoff)
      else
        query
      end

    Repo.all(query)
  end

  def duplicate_identity_warning?(%IdentityVerification{identity_hash: hash})
      when hash in [nil, ""],
      do: false

  def duplicate_identity_warning?(%IdentityVerification{} = verification) do
    from(v in IdentityVerification,
      where: v.identity_hash == ^verification.identity_hash and v.id != ^verification.id,
      select: count(v.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp parse_hours(value) when is_integer(value) and value >= 0, do: value

  defp parse_hours(value) when is_binary(value) do
    case Integer.parse(value) do
      {hours, ""} when hours >= 0 -> hours
      _ -> nil
    end
  end

  defp parse_hours(_value), do: nil

  @doc "Fetches one verification with its owning user preloaded."
  def get(id) do
    with true <- is_binary(id),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %IdentityVerification{} = verification <- Repo.get(IdentityVerification, uuid) do
      Repo.preload(verification, :user)
    else
      _ -> nil
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

  defp purge_document(%IdentityVerification{document_image: path})
       when is_binary(path) and path != "" do
    %{
      bucket: VerificationDocument.bucket(),
      key: String.trim_leading(path, "/")
    }
    |> DeleteR2ObjectWorker.new()
    |> Oban.insert()

    :ok
  end

  defp purge_document(_verification), do: :ok
end
