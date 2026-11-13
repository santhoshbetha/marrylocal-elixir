defmodule MarrylocalWeb.ProfilesController do
  @moduledoc """
  Profile reads and the locale-first discovery feed.
  """

  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Accounts
  alias Marrylocal.Discovery
  alias Marrylocal.Features
  alias Marrylocal.Geo
  alias Marrylocal.Relationships
  alias Marrylocal.Uploaders.Avatar
  alias Marrylocal.Uploaders.ProfilePhoto
  alias Marrylocal.Workers.DeleteR2ObjectWorker
  alias MarrylocalWeb.UserJSON

  @max_photo_slots 10
  @avatar_max_bytes 5 * 1024 * 1024

  @doc """
  GET /api/v1/profiles/discovery

  Returns opposite-gender profiles inside the viewer's PostGIS locale radius,
  nearest first. Lifestyle filters are optional query parameters.
  """
  def discovery(conn, params) do
    user = conn.assigns.current_user

    cond do
      user.force_verification_required ->
        verification_required(conn)

      Features.payment_enforcement_active?(user) ->
        payment_required(conn)

      true ->
        case Discovery.discover(user, params) do
          {:ok, result} ->
            conn
            |> put_status(:ok)
            |> json(%{
              status: "success",
              data: %{
                profiles: result.profiles,
                pagination: result.pagination,
                locale: result.locale,
                search_mode: result.search_mode,
                has_more: result.has_more,
                next_cursor: result.next_cursor
              }
            })

          {:error, :location_required} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              status: "error",
              code: "location_required",
              message: "Add a city or coordinates before opening discovery."
            })

          {:error, :unsupported_gender} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              status: "error",
              code: "unsupported_gender",
              message: "Discovery requires a male or female gender preference."
            })
        end
    end
  end

  @doc """
  GET /api/v1/profiles/lookup?query=...

  Looks up one active profile by a complete email address or a 10-digit phone
  number. The response uses the same public card shape as discovery so the
  client can open the detailed profile view immediately.
  """
  def lookup(conn, %{"query" => query}) when is_binary(query) do
    viewer = conn.assigns.current_user
    query = String.trim(query)

    cond do
      viewer.force_verification_required ->
        verification_required(conn)

      Features.payment_enforcement_active?(viewer) ->
        payment_required(conn)

      true ->
        case Discovery.lookup_profile(viewer, query) do
          %{user_state: :active} = user ->
            conn
            |> put_status(:ok)
            |> json(%{status: "success", data: %{profile: UserJSON.public_profile(user)}})

          _ ->
            lookup_not_found(conn)
        end
    end
  end

  def lookup(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "missing_query",
      message: "Enter an email, phone number, or handle."
    })
  end

  @doc "GET /api/v1/profiles/me"
  def me(conn, _params) do
    user = conn.assigns.current_user |> Accounts.refresh_gating()

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: %{profile: UserJSON.profile(user)}})
  end

  @doc """
  PATCH /api/v1/profiles/me

  Updates lifestyle/profile fields and, when coordinates are present, the
  PostGIS geography point. The operation is atomic.
  """
  def update(conn, params) do
    user = conn.assigns.current_user
    profile_attrs = extract_profile_params(params)
    coords = extract_coordinates(params)

    case Accounts.update_profile_and_location(user, profile_attrs, coords) do
      {:ok, updated} ->
        maybe_enqueue_seed_recruitment(user, updated)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Profile updated",
          data: %{profile: UserJSON.profile(updated)}
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  @doc """
  PATCH /api/v1/profiles/me/location

  Updates one location slot. Secondary slots require an active monthly addon
  and each slot has an independent 30-day change cooldown.
  """
  def update_location(conn, params) do
    user = conn.assigns.current_user
    attrs = extract_location_params(params)
    slot = params["slot"] || params["location_slot"] || "primary"

    case Accounts.update_location_slot(user, slot, attrs) do
      {:ok, updated} ->
        maybe_enqueue_seed_recruitment(user, updated)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Location updated",
          data: %{profile: UserJSON.profile(updated)}
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  @doc """
  POST /api/v1/profiles/me/avatar

  Multipart upload shared by the primary avatar and the ten gallery slots.

    * without `slot_index` -> replaces `users.avatar`
    * with `slot_index` 0..9 -> stores the file under
      `uploads/users/<id>/photos/<slot>/` and writes the public URL into
      `users.images[slot_index]`

  The bearer token identifies the owner; no user id is accepted from the
  payload.
  """
  def upload_avatar(conn, params) do
    user = conn.assigns.current_user

    # Waffle/ExAws perform a storage request while persisting the photo. A DNS
    # failure, expired R2 credentials, or a dropped connection must surface as a
    # readable JSON error instead of tearing down the request process (which the
    # browser would report as a CORS failure because the 500 has no headers).
    try do
      with {:ok, upload} <- extract_avatar_upload(params),
           :ok <- Marrylocal.Uploads.validate_size(upload, @avatar_max_bytes),
           {:ok, photo_hash} <- ensure_unique_photo(user, upload),
           {:ok, destination} <- upload_destination(params) do
        case destination do
          :avatar -> upload_primary_avatar(conn, user, upload, photo_hash)
          {:slot, slot_index} -> upload_profile_photo(conn, user, upload, slot_index, photo_hash)
        end
      else
        {:error, :duplicate_photo} ->
          duplicate_photo_error(conn)

        {:error, :file_too_large} ->
          file_too_large_error(conn, "Photos must be 5 MB or smaller.")

        {:error, :invalid_upload} ->
          invalid_avatar_error(conn)

        {:error, :missing_avatar} ->
          missing_avatar_error(conn)

        {:error, :invalid_slot_index} ->
          invalid_slot_index_error(conn)

        {:error, %Ecto.Changeset{} = changeset} ->
          log_avatar_changeset_failure(conn, user, changeset)
          handle_avatar_changeset_error(conn, changeset)

        {:error, reason} ->
          log_avatar_storage_diagnostics(conn, user, reason)
          handle_error(conn, reason)
      end
    rescue
      exception ->
        Logger.error("❌ CLOUDFLARE R2 UPLOAD FAILURE EXCEPTION: #{inspect(exception)}")

        Logger.error(
          "❌ CLOUDFLARE R2 UPLOAD FAILURE STACKTRACE: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        log_avatar_storage_diagnostics(conn, user, exception)

        avatar_storage_error(conn, exception)
    catch
      kind, reason ->
        Logger.error("❌ CLOUDFLARE R2 UPLOAD FAILURE CATCH: #{inspect({kind, reason})}")

        log_avatar_storage_diagnostics(conn, user, {kind, reason})

        avatar_storage_error(conn, {kind, reason})
    end
  end

  defp upload_primary_avatar(conn, user, upload, photo_hash) do
    old_avatar = user.avatar

    case Accounts.update_avatar_with_photo_hash(user, %{avatar: upload}, photo_hash) do
      {:ok, updated} ->
        maybe_delete_replaced_avatar(user, old_avatar, updated.avatar)

        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message: "Avatar uploaded successfully",
          data: %{
            slot_index: nil,
            avatar_url: Avatar.url({updated.avatar, updated}),
            profile: UserJSON.profile(updated)
          }
        })

      {:error, :duplicate_photo} ->
        cleanup_rejected_avatar_upload(user, old_avatar, upload)
        duplicate_photo_error(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        cleanup_rejected_avatar_upload(user, old_avatar, upload)
        log_avatar_changeset_failure(conn, user, changeset)
        handle_avatar_changeset_error(conn, changeset)

      {:error, reason} ->
        log_avatar_storage_diagnostics(conn, user, reason)
        handle_error(conn, reason)
    end
  end

  defp upload_profile_photo(conn, user, upload, slot_index, photo_hash) do
    scope = %{user_id: user.id, slot_index: slot_index}
    old_url = user.images |> List.wrap() |> Enum.at(slot_index)

    case ProfilePhoto.store({upload, scope}) do
      {:ok, file_name} ->
        case ProfilePhoto.url({file_name, scope}) do
          image_url when is_binary(image_url) ->
            persist_profile_photo(
              conn,
              user,
              image_url,
              slot_index,
              photo_hash,
              old_url
            )

          _other ->
            Logger.error(
              "❌ CLOUDFLARE R2 SLOT UPLOAD FAILURE slot=#{slot_index}: " <>
                "could not build a public URL"
            )

            avatar_storage_error(conn, :invalid_public_url)
        end

      {:error, :invalid_file} ->
        invalid_avatar_error(conn)

      {:error, reason} ->
        Logger.error("❌ CLOUDFLARE R2 SLOT UPLOAD FAILURE slot=#{slot_index}: #{inspect(reason)}")

        log_avatar_storage_diagnostics(conn, user, reason)
        avatar_storage_error(conn, reason)
    end
  end

  defp persist_profile_photo(conn, user, image_url, slot_index, photo_hash, old_url) do
    case Accounts.update_user_image_at_slot_with_photo_hash(
           user,
           image_url,
           slot_index,
           photo_hash
         ) do
      {:ok, updated} ->
        maybe_delete_replaced_gallery_photo(old_url, image_url)

        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message: "Photo uploaded to slot #{slot_index}",
          data: %{
            slot_index: slot_index,
            image_url: image_url,
            profile: UserJSON.profile(updated)
          }
        })

      {:error, :duplicate_photo} ->
        cleanup_rejected_gallery_upload(image_url, old_url)
        duplicate_photo_error(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        cleanup_rejected_gallery_upload(image_url, old_url)
        log_avatar_changeset_failure(conn, user, changeset)
        handle_avatar_changeset_error(conn, changeset)

      {:error, reason} ->
        log_avatar_storage_diagnostics(conn, user, reason)
        handle_error(conn, reason)
    end
  end

  @doc "DELETE /api/v1/profiles/me/photos/:slot_index"
  def delete_photo(conn, %{"slot_index" => value}) do
    user = conn.assigns.current_user

    case parse_slot_index(value) do
      {:ok, slot_index} ->
        old_url = user.images |> List.wrap() |> Enum.at(slot_index)

        case Accounts.clear_user_image_at_slot(user, slot_index) do
          {:ok, updated} ->
            enqueue_r2_delete(url_to_key(old_url))
            Accounts.release_photo_hash(updated, slot_index)

            conn
            |> put_status(:ok)
            |> json(%{
              status: "success",
              message: "Photo removed from slot #{slot_index}",
              data: %{
                slot_index: slot_index,
                profile: UserJSON.profile(updated)
              }
            })

          {:error, %Ecto.Changeset{} = changeset} ->
            log_avatar_changeset_failure(conn, user, changeset)
            handle_avatar_changeset_error(conn, changeset)

          {:error, reason} ->
            handle_error(conn, reason)
        end

      :error ->
        invalid_slot_index_error(conn)
    end
  end

  @doc "DELETE /api/v1/profiles/me/avatar"
  def delete_avatar(conn, _params) do
    user = conn.assigns.current_user
    old_avatar = user.avatar

    case Accounts.clear_avatar(user) do
      {:ok, updated} ->
        enqueue_r2_delete(avatar_object_key(user, old_avatar))
        Accounts.release_photo_hash(updated, nil)

        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Avatar removed",
          data: %{avatar_url: nil, profile: UserJSON.profile(updated)}
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  defp upload_destination(%{"slot_index" => value}) do
    case parse_slot_index(value) do
      {:ok, slot_index} -> {:ok, {:slot, slot_index}}
      :error -> {:error, :invalid_slot_index}
    end
  end

  defp upload_destination(_params), do: {:ok, :avatar}

  defp parse_slot_index(value) when is_integer(value) do
    if value in 0..(@max_photo_slots - 1), do: {:ok, value}, else: :error
  end

  defp parse_slot_index(value) do
    case Integer.parse(to_string(value)) do
      {index, ""} -> parse_slot_index(index)
      _ -> :error
    end
  end

  defp missing_avatar_error(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "missing_avatar",
      message: "Attach an image under the `avatar` field."
    })
  end

  defp invalid_slot_index_error(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "invalid_slot_index",
      message: "slot_index must be an integer between 0 and #{@max_photo_slots - 1}."
    })
  end

  defp invalid_avatar_error(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "invalid_avatar",
      message: "Only PNG and JPEG images up to 5 MB are supported."
    })
  end

  defp extract_avatar_upload(%{"avatar" => %Plug.Upload{} = upload}), do: {:ok, upload}

  defp extract_avatar_upload(%{"avatar" => %{"file" => %Plug.Upload{} = upload}}),
    do: {:ok, upload}

  defp extract_avatar_upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}
  defp extract_avatar_upload(_params), do: {:error, :missing_avatar}

  defp ensure_unique_photo(user, %Plug.Upload{} = upload) do
    photo_hash = Accounts.profile_photo_hash(upload.path)

    cond do
      is_nil(photo_hash) or photo_hash == "" ->
        {:ok, nil}

      Accounts.photo_hash_claimed?(photo_hash, user.id) ->
        {:error, :duplicate_photo}

      true ->
        {:ok, photo_hash}
    end
  end

  defp file_too_large_error(conn, message) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{
      status: "error",
      code: "file_too_large",
      message: message
    })
  end

  defp maybe_delete_replaced_avatar(user, old_avatar, new_avatar) do
    old_key = avatar_object_key(user, old_avatar)
    new_key = avatar_object_key(user, new_avatar)

    if old_key && old_key != new_key do
      enqueue_r2_delete(old_key)
    end

    :ok
  end

  defp cleanup_rejected_avatar_upload(user, old_avatar, %Plug.Upload{} = upload) do
    new_key = uploaded_avatar_object_key(user, upload)
    old_key = avatar_object_key(user, old_avatar)

    # With stable `original.<ext>` keys, a same-extension replacement has
    # already overwritten the previous avatar. Deleting it here would break the
    # row that the rolled-back transaction left intact, so only clean up a key
    # that is genuinely new.
    if new_key && new_key != old_key do
      enqueue_r2_delete(new_key)
    end

    :ok
  end

  defp maybe_delete_replaced_gallery_photo(old_url, new_url) do
    old_key = url_to_key(old_url)
    new_key = url_to_key(new_url)

    if old_key && old_key != new_key do
      enqueue_r2_delete(old_key)
    end

    :ok
  end

  defp cleanup_rejected_gallery_upload(new_url, old_url) do
    new_key = url_to_key(new_url)
    old_key = url_to_key(old_url)

    if new_key && new_key != old_key do
      enqueue_r2_delete(new_key)
    end

    :ok
  end

  defp avatar_object_key(_user, nil), do: nil

  defp avatar_object_key(user, %{file_name: file_name}) when is_binary(file_name) do
    Path.join(
      Avatar.storage_dir(:original, {%{file_name: file_name}, user}),
      file_name
    )
  end

  defp avatar_object_key(_user, _avatar), do: nil

  defp uploaded_avatar_object_key(user, %Plug.Upload{} = upload) do
    extension = upload.filename |> Path.extname() |> String.downcase()

    if extension in ~w(.png .jpg .jpeg) do
      Path.join(
        Avatar.storage_dir(:original, {upload, user}),
        "original#{extension}"
      )
    end
  end

  defp url_to_key(nil), do: nil

  defp url_to_key(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" ->
        String.trim_leading(path, "/")

      _ ->
        nil
    end
  end

  defp enqueue_r2_delete(nil), do: :ok

  defp enqueue_r2_delete(key) when is_binary(key) and key != "" do
    %{
      bucket: System.get_env("AWS_S3_BUCKET") || "marrylocal",
      key: String.trim_leading(key, "/")
    }
    |> DeleteR2ObjectWorker.new()
    |> Oban.insert()

    :ok
  end

  defp enqueue_r2_delete(_key), do: :ok

  defp duplicate_photo_error(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{
      status: "error",
      code: "duplicate_photo",
      message: "This photo is already active on another profile."
    })
  end

  defp handle_avatar_changeset_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

    if Map.has_key?(errors, :avatar) or Map.has_key?(errors, :images) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        status: "error",
        code: "invalid_avatar",
        message: "Only PNG and JPEG images up to 5 MB are supported.",
        errors: errors
      })
    else
      handle_error(conn, changeset)
    end
  end

  defp avatar_storage_error(conn, error) do
    payload = %{
      status: "error",
      code: "avatar_storage_unavailable",
      message:
        "Your photo could not be stored because the image storage service is unavailable. Please try again in a moment."
    }

    payload =
      if Application.get_env(:marrylocal, :env, :prod) == :prod do
        payload
      else
        Map.put(payload, :details, describe_storage_error(error))
      end

    conn
    |> put_status(:bad_gateway)
    |> json(payload)
  end

  defp describe_storage_error(%{__exception__: true} = exception),
    do: Exception.message(exception)

  defp describe_storage_error(other), do: inspect(other)

  # Waffle uploads during `Waffle.Ecto.Type.cast/2`, so a rejected R2 request
  # arrives here as an invalid changeset rather than an exception. Log the
  # changeset in full; Waffle logs the raw `{:http_error, status, body}` tuple
  # immediately before this line, together giving the exact provider response.
  defp log_avatar_changeset_failure(conn, user, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        %{message: message, opts: opts}
      end)

    Logger.error(
      "❌ CLOUDFLARE R2 UPLOAD FAILURE CHANGESET " <>
        "user_id=#{user.id} " <>
        "request_id=#{inspect(request_id(conn))} " <>
        "bucket=#{inspect(Application.get_env(:waffle, :bucket))} " <>
        "endpoint=#{avatar_storage_endpoint()} " <>
        "credentials_configured=#{avatar_storage_credentials_configured?()} " <>
        "errors=#{inspect(errors)}"
    )
  end

  # Structured triage line for exceptions, throws, and raw error tuples. The
  # status/hint pair makes 403 (credentials or bucket policy) and 404 (endpoint
  # or bucket routing) immediately distinguishable in the terminal.
  defp log_avatar_storage_diagnostics(conn, user, error) do
    status = avatar_storage_status(error)

    Logger.error(
      "❌ CLOUDFLARE R2 UPLOAD DIAGNOSTICS " <>
        "user_id=#{user.id} " <>
        "request_id=#{inspect(request_id(conn))} " <>
        "status=#{inspect(status)} " <>
        "status_hint=#{avatar_storage_hint(status)} " <>
        "bucket=#{inspect(Application.get_env(:waffle, :bucket))} " <>
        "endpoint=#{avatar_storage_endpoint()} " <>
        "credentials_configured=#{avatar_storage_credentials_configured?()} " <>
        "error=#{inspect(error)}"
    )
  end

  defp request_id(conn) do
    conn.assigns[:request_id] || Logger.metadata()[:request_id]
  end

  defp avatar_storage_status({:http_error, status, _body}) when is_integer(status), do: status
  defp avatar_storage_status({:http_error, status}) when is_integer(status), do: status
  defp avatar_storage_status(%{status_code: status}) when is_integer(status), do: status
  defp avatar_storage_status(%{status: status}) when is_integer(status), do: status
  defp avatar_storage_status(%{reason: reason}), do: avatar_storage_status(reason)
  defp avatar_storage_status({_context, reason}), do: avatar_storage_status(reason)
  defp avatar_storage_status(_other), do: nil

  defp avatar_storage_hint(401), do: "credentials_missing_or_rejected"
  defp avatar_storage_hint(403), do: "credentials_forbidden_or_bucket_policy"
  defp avatar_storage_hint(404), do: "endpoint_or_bucket_not_found"
  defp avatar_storage_hint(400), do: "malformed_request_or_bucket_configuration"

  defp avatar_storage_hint(status) when is_integer(status) and status in 500..599,
    do: "provider_outage"

  defp avatar_storage_hint(_status), do: "unclassified_check_error_payload"

  defp avatar_storage_endpoint do
    config = Application.get_env(:ex_aws, :s3) || []
    scheme = Keyword.get(config, :scheme, "https://")
    host = Keyword.get(config, :host)

    if is_binary(host) and host != "" do
      "#{scheme}#{host}"
    else
      "not_configured"
    end
  end

  defp avatar_storage_credentials_configured? do
    access_key = Application.get_env(:ex_aws, :access_key_id)
    secret_key = Application.get_env(:ex_aws, :secret_access_key)

    is_binary(access_key) and access_key != "" and is_binary(secret_key) and secret_key != ""
  end

  @doc """
  GET /api/v1/profiles?handle=...&

  Fast handle lookup used by the Search User tab. Returns a single public
  profile; search stays disabled client-side until at least three characters
  are entered.
  """
  def index(conn, %{"handle" => handle}) when is_binary(handle) do
    handle = String.trim(handle)
    viewer = conn.assigns.current_user

    cond do
      viewer.force_verification_required ->
        verification_required(conn)

      Features.payment_enforcement_active?(viewer) ->
        payment_required(conn)

      true ->
        case Discovery.lookup_profile(viewer, "@#{handle}") do
          %{user_state: :active} = user ->
            conn
            |> put_status(:ok)
            |> json(%{status: "success", data: %{profile: UserJSON.public_profile(user)}})

          _ ->
            lookup_not_found(conn)
        end
    end
  end

  def index(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", code: "missing_handle", message: "A handle is required."})
  end

  @doc """
  GET /api/v1/profiles/:id

  Returns a public profile unless the viewer has already been matched. Exact
  coordinates, email, and phone are never serialized.
  """
  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user

    cond do
      to_string(viewer.id) == to_string(id) ->
        me(conn, %{})

      true ->
        case resolve_profile(id) do
          %{user_state: :active} = user ->
            if Relationships.hidden?(viewer.id, user.id) do
              not_found(conn)
            else
              profile =
                UserJSON.public_profile(user)
                |> Map.merge(%{
                  is_shortlisted: Relationships.relationship?(viewer.id, user.id, :shortlist),
                  is_liked: Relationships.relationship?(viewer.id, user.id, :like),
                  is_matched: Relationships.relationship?(viewer.id, user.id, :match),
                  is_blocked: Relationships.relationship?(viewer.id, user.id, :block),
                  is_muted: Relationships.relationship?(viewer.id, user.id, :mute)
                })
                |> with_viewer_distance(viewer, user)

              conn
              |> put_status(:ok)
              |> json(%{status: "success", data: %{profile: profile}})
            end

          _ ->
            not_found(conn)
        end
    end
  end

  defp resolve_profile(id) do
    case parse_id(id) do
      {:ok, user_id} -> Accounts.get_user(user_id)
      :error -> Accounts.get_user_by_shortid(id)
    end
  end

  # Discovery already returns a rounded distance for each card. The standalone
  # profile endpoint needs the same viewer-relative value for its header badge.
  defp with_viewer_distance(profile, viewer, user) do
    with {:ok, viewer_point} <- Geo.point_for(viewer),
         {:ok, user_point} <- Geo.point_for(user) do
      UserJSON.with_distance(profile, Geo.haversine_km(viewer_point, user_point))
    else
      _ -> UserJSON.with_distance(profile, nil)
    end
  end

  @doc """
  POST /api/v1/profiles/me/shortlist/:target_id

  Shortlisting is a private relationship, not a notification event.
  """
  def shortlist(conn, %{"target_id" => target_id}) do
    user = conn.assigns.current_user

    case Relationships.create_relationship_with_status(user.id, target_id, :shortlist) do
      {:ok, _relationship, _inserted?, notifications} ->
        Relationships.broadcast_notifications(notifications)

        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message: "Profile shortlisted",
          data: %{relationships: Relationships.summary(user.id)}
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  defp handle_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Validation failed", errors: errors})
  end

  defp handle_error(conn, :core_details_locked) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "core_details_locked",
      message: "Name, language, and community can only be updated once."
    })
  end

  defp handle_error(conn, :target_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Profile not found"})
  end

  defp handle_error(conn, :duplicate_location) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      message: "You already have this city assigned to another active location."
    })
  end

  defp handle_error(conn, :location_change_locked) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "location_change_locked",
      message: "This location can only be changed once every 30 days."
    })
  end

  defp handle_error(conn, :location_addon_required) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      status: "error",
      code: "LOCATION_ADDON_REQUIRED",
      message: "This location addon is not active for your account."
    })
  end

  defp handle_error(conn, :invalid_location_slot) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "invalid_location_slot",
      message: "Choose primary, location_2, or location_3."
    })
  end

  defp handle_error(conn, :invalid_location) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "invalid_location",
      message: "A valid state, city, latitude, and longitude are required."
    })
  end

  defp handle_error(conn, :self_relationship) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "You cannot shortlist your own profile."})
  end

  defp handle_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Unable to save profile action: #{inspect(reason)}"})
  end

  defp extract_profile_params(%{"profile" => profile}) when is_map(profile), do: profile

  defp extract_profile_params(params) do
    Map.drop(params, ["latitude", "longitude", "raw_lat", "raw_lon", "slot", "location_slot"])
  end

  defp extract_location_params(params) do
    %{
      "state" => params["state"],
      "city" => params["city"],
      "latitude" => params["latitude"] || params["lat"],
      "longitude" => params["longitude"] || params["lng"]
    }
  end

  defp extract_coordinates(params) do
    latitude = params["latitude"] || params["raw_lat"] || params["lat"]
    longitude = params["longitude"] || params["raw_lon"] || params["lng"]

    if present?(latitude) and present?(longitude) do
      %{"latitude" => latitude, "longitude" => longitude}
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""

  # A member joining or moving into a city can unblock the seed-verifier
  # pipeline, so ask the recruitment worker to top that city up.
  defp maybe_enqueue_seed_recruitment(previous, updated) do
    if seed_city_changed?(previous, updated) do
      %{"city" => updated.city, "state" => updated.state}
      |> Marrylocal.Workers.CitySeedRecruitmentWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp seed_city_changed?(previous, updated) do
    present?(updated.city) and present?(updated.state) and
      (normalized_location(updated.city) != normalized_location(previous.city) or
         normalized_location(updated.state) != normalized_location(previous.state))
  end

  defp normalized_location(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalized_location(_value), do: nil

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_id(_id), do: :error

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Profile not found"})
  end

  defp lookup_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "No matching profile found."})
  end

  defp verification_required(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      status: "error",
      code: "VERIFICATION_REQUIRED",
      message: "Identity verification is required to continue searching in your area."
    })
  end

  defp payment_required(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      status: "error",
      code: "PAYMENT_REQUIRED",
      message: "Annual service fee payment is required to continue searching."
    })
  end
end
