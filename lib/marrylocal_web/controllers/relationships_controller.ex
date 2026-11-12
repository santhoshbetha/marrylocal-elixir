defmodule MarrylocalWeb.RelationshipsController do
  @moduledoc """
  Stateful profile-discovery interactions: like, dislike, shortlist, match.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Relationships
  alias MarrylocalWeb.UserJSON

  @doc "GET /api/v1/relationships"
  def index(conn, _params) do
    user = conn.assigns.current_user

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: %{relationships: Relationships.summary(user.id)}})
  end

  @doc "GET /api/v1/relationships/shortlisted"
  def shortlisted(conn, params) do
    user = conn.assigns.current_user

    result =
      Relationships.list_shortlisted_users_paginated(user.id,
        page: params["page"],
        per_page: params["per_page"]
      )

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        kind: "shortlisted",
        users: user_payloads(user.id, result.users),
        pagination: result.pagination
      }
    })
  end

  @doc "GET /api/v1/relationships/liked-me"
  def liked_me(conn, params) do
    user = conn.assigns.current_user

    result =
      Relationships.list_liked_me_users_paginated(user.id,
        page: params["page"],
        per_page: params["per_page"]
      )

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        kind: "liked_me",
        users: user_payloads(user.id, result.users),
        pagination: result.pagination
      }
    })
  end

  @doc "GET /api/v1/relationships/blocked"
  def blocked(conn, _params) do
    user = conn.assigns.current_user
    users = Relationships.list_blocked_users(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{kind: "blocked", users: user_payloads(user.id, users)}
    })
  end

  @doc "GET /api/v1/relationships/muted"
  def muted(conn, _params) do
    user = conn.assigns.current_user
    users = Relationships.list_muted_users(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{kind: "muted", users: user_payloads(user.id, users)}
    })
  end

  @doc "GET /api/v1/relationships/moderated"
  def moderated(conn, _params) do
    user = conn.assigns.current_user
    %{blocked: blocked, muted: muted} = Relationships.list_moderated_users(user.id)

    conn
    |> put_status(:ok)
    |> json(%{
      status: "success",
      data: %{
        kind: "moderated",
        blocked: user_payloads(user.id, blocked),
        muted: user_payloads(user.id, muted),
        counts: %{blocked: length(blocked), muted: length(muted)}
      }
    })
  end

  @doc """
  POST /api/v1/relationships

  Body: `%{"kind" => "like" | "dislike" | "shortlist", "target_id" => 123}`

  A like that completes a mutual match writes both match rows and both
  notifications inside one transaction. Pushes are emitted only after commit.
  """
  def create(conn, params) do
    actor = conn.assigns.current_user
    kind = params["kind"]
    target_id = params["target_id"] || params["user_id"] || params["targetId"]

    case Relationships.create_relationship_with_status(actor.id, target_id, kind) do
      {:ok, relationship, inserted?, notifications} ->
        Relationships.broadcast_notifications(notifications)
        match? = Enum.any?(notifications, &(&1.type == :mutual_match))

        conn
        |> put_status(:created)
        |> json(%{
          status: "success",
          message: if(match?, do: "It's a match!", else: "Relationship saved"),
          data: %{
            relationship: %{
              kind: relationship.kind,
              target_id: relationship.target_id
            },
            inserted: inserted?,
            is_match: match?,
            notifications: Enum.map(notifications, &Marrylocal.Notifications.payload/1),
            relationships: Relationships.summary(actor.id)
          }
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  @doc "DELETE /api/v1/relationships/:kind/:target_id"
  def delete(conn, %{"kind" => kind, "target_id" => target_id}) do
    actor = conn.assigns.current_user

    case Relationships.delete_relationship(actor.id, target_id, kind) do
      {:ok, deleted_kind} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          message: "Relationship removed",
          data: %{
            relationship: %{kind: deleted_kind, target_id: target_id},
            relationships: Relationships.summary(actor.id)
          }
        })

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  defp user_payloads(viewer_id, users) do
    flags = Relationships.relationship_flags(viewer_id, Enum.map(users, & &1.id))
    default_flags = %{is_liked: false, is_shortlisted: false, is_matched: false}

    Enum.map(users, fn user ->
      UserJSON.public_profile(user)
      |> Map.merge(Map.get(flags, user.id, default_flags))
    end)
  end

  defp handle_error(conn, :invalid_kind) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      message: "kind must be one of like, dislike, shortlist, match, mute, or block"
    })
  end

  defp handle_error(conn, :blocked) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      status: "error",
      message: "You cannot interact with a blocked or muted profile."
    })
  end

  defp handle_error(conn, :target_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "error", message: "Target profile not found"})
  end

  defp handle_error(conn, :self_relationship) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "You cannot interact with your own profile"})
  end

  defp handle_error(conn, %Ecto.Changeset{} = changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Validation failed", errors: errors})
  end

  defp handle_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: "Unable to save relationship: #{inspect(reason)}"})
  end
end
