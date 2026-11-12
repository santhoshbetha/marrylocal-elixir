defmodule Marrylocal.Relationships do
  @moduledoc """
  Profile-discovery state machine.

  MarryLocal has no events, comments, or venues. Discovery is a sequence of
  stateful profile interactions, so every action is a directed row in
  `relationships`:

    * `:like`      - interested in the profile
    * `:dislike`   - not interested; excluded from future discovery
    * `:shortlist` - saved for later (private to the actor)
    * `:match`     - written symmetrically when two likes meet

  The mutual match, its two notification rows, and the originating like are all
  written in one transaction. WebSocket pushes happen only after that
  transaction commits.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Marrylocal.Accounts.User
  alias Marrylocal.Notifications
  alias Marrylocal.Repo
  alias Marrylocal.Relationships.Relationship

  @kinds [:like, :dislike, :shortlist, :match, :mute, :block]
  @acted_on_kinds [:like, :dislike, :shortlist, :match]
  @hidden_kinds [:mute, :block]
  @default_per_page 20
  @max_per_page 20

  def kinds, do: @kinds

  @doc """
  Creates a relationship and reports whether the row was newly inserted.

  Returns the notifications that were written in the same transaction so the
  controller can broadcast after commit via `broadcast_notifications/1`.
  """
  def create_relationship_with_status(actor_id, target_id, kind) do
    with {:ok, kind} <- cast_kind(kind),
         {:ok, target_id} <- normalize_id(target_id),
         :ok <- ensure_not_self(actor_id, target_id),
         :ok <- ensure_not_hidden(actor_id, target_id, kind),
         {:ok, target} <- fetch_user(target_id),
         {:ok, actor} <- fetch_user(actor_id) do
      result =
        Repo.transaction(fn ->
          prepare_relationship_rows(actor_id, target_id, kind)

          case get_or_insert(actor_id, target_id, kind) do
            {:ok, relationship, false} ->
              {:ok, relationship, false, []}

            {:ok, relationship, true} ->
              notifications = maybe_create_notifications(actor, target, kind)
              {:ok, relationship, true, notifications}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, {:ok, relationship, inserted?, notifications}} ->
          {:ok, relationship, inserted?, notifications}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Creates a relationship without returning the inserted flag."
  def create_relationship(actor_id, target_id, kind) do
    case create_relationship_with_status(actor_id, target_id, kind) do
      {:ok, relationship, _inserted?, notifications} ->
        broadcast_notifications(notifications)
        {:ok, relationship}

      error ->
        error
    end
  end

  @doc """
  Removes one directed relationship.

  Removing a like also dissolves any derived match rows, in both directions, so
  the match list can never show a pair whose like no longer exists.
  """
  def delete_relationship(actor_id, target_id, kind) do
    with {:ok, kind} <- cast_kind(kind),
         {:ok, target_id} <- normalize_id(target_id) do
      Repo.transaction(fn ->
        delete_pair(actor_id, target_id, kind)

        if kind == :like do
          delete_pair(actor_id, target_id, :match)
          delete_pair(target_id, actor_id, :match)
        end

        {:ok, kind}
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Broadcasts transaction-committed notifications to their owners."
  def broadcast_notifications(notifications) when is_list(notifications) do
    Notifications.broadcast_many(notifications)
  end

  @doc """
  Returns the acting user's relationship summary.

  `matches` is read from the symmetric `:match` rows written by the match
  transaction. `likes`, `dislikes`, and `shortlists` are the actor's own
  outgoing choices.
  """
  def summary(user_id) do
    %{
      likes: ids_for(user_id, :like),
      dislikes: ids_for(user_id, :dislike),
      shortlists: ids_for(user_id, :shortlist),
      matches: ids_for(user_id, :match),
      blocks: ids_for(user_id, :block),
      mutes: ids_for(user_id, :mute)
    }
  end

  @doc "True when the actor has the given relationship kind toward the target."
  def relationship?(actor_id, target_id, kind) when kind in @kinds do
    Repo.exists?(
      from(r in Relationship,
        where: r.actor_id == ^actor_id and r.target_id == ^target_id and r.kind == ^kind
      )
    )
  end

  def relationship?(_actor_id, _target_id, _kind), do: false

  @doc """
  True when either user has blocked the other.

  Blocks are bidirectional for visibility: if either side blocks, neither user
  can discover or directly open the other.
  """
  def blocked?(user_id, other_id) when is_integer(user_id) and is_integer(other_id) do
    user_id != other_id and
      Repo.exists?(
        from(r in Relationship,
          where:
            r.kind == :block and
              ((r.actor_id == ^user_id and r.target_id == ^other_id) or
                 (r.actor_id == ^other_id and r.target_id == ^user_id))
        )
      )
  end

  def blocked?(_user_id, _other_id), do: false

  @doc """
  True when either user has blocked or muted the other.

  Mutes are intentionally also treated as a two-sided visibility boundary so a
  muted profile cannot keep appearing in the muting user's feed.
  """
  def hidden?(user_id, other_id) when is_integer(user_id) and is_integer(other_id) do
    user_id != other_id and
      Repo.exists?(
        from(r in Relationship,
          where:
            r.kind in ^@hidden_kinds and
              ((r.actor_id == ^user_id and r.target_id == ^other_id) or
                 (r.actor_id == ^other_id and r.target_id == ^user_id))
        )
      )
  end

  def hidden?(_user_id, _other_id), do: false

  @doc """
  Excludes every profile connected to the viewer by a block or mute row in
  either direction.
  """
  def exclude_hidden(query, nil), do: query

  def exclude_hidden(query, viewer_id) do
    hidden_ids =
      from(r in Relationship,
        where: r.kind in ^@hidden_kinds,
        where: r.actor_id == ^viewer_id or r.target_id == ^viewer_id,
        select:
          fragment(
            "CASE WHEN ? = ? THEN ? ELSE ? END",
            r.actor_id,
            ^viewer_id,
            r.target_id,
            r.actor_id
          )
      )

    from(u in query, where: u.id not in subquery(hidden_ids))
  end

  @doc "Returns the users the actor has blocked."
  def list_blocked_users(user_id), do: users_for(user_id, :block)

  @doc "Returns the users the actor has muted."
  def list_muted_users(user_id), do: users_for(user_id, :mute)

  @doc "Returns both moderation lists for the settings panel."
  def list_moderated_users(user_id) do
    %{
      blocked: list_blocked_users(user_id),
      muted: list_muted_users(user_id)
    }
  end

  @doc "True when the actor has already acted on the target in any way."
  def acted_on?(user_id, target_id) do
    Repo.exists?(
      from(r in Relationship,
        where:
          r.actor_id == ^user_id and r.target_id == ^target_id and
            r.kind in ^@acted_on_kinds
      )
    )
  end

  @doc """
  Excludes every profile the viewer has already liked, disliked, shortlisted, or
  matched. Used by the discovery feed so cards never repeat.
  """
  def exclude_acted_on(query, nil), do: query

  def exclude_acted_on(query, viewer_id) do
    acted_on_ids =
      from(r in Relationship,
        where: r.actor_id == ^viewer_id and r.kind in ^@acted_on_kinds,
        select: r.target_id
      )

    from(u in query, where: u.id not in subquery(acted_on_ids))
  end

  @doc "Returns the profiles the actor shortlisted, newest first."
  def list_shortlisted_users(user_id) do
    from(u in User,
      join: r in Relationship,
      on: r.target_id == u.id,
      where: r.actor_id == ^user_id and r.kind == :shortlist,
      where: u.user_state == :active,
      order_by: [desc: r.inserted_at],
      select: u
    )
    |> exclude_hidden(user_id)
    |> Repo.all()
  end

  @doc "Returns a bounded page of profiles the actor shortlisted."
  def list_shortlisted_users_paginated(user_id, opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> normalize_positive(1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> normalize_per_page()

    base =
      from(u in User,
        join: r in Relationship,
        on: r.target_id == u.id,
        where: r.actor_id == ^user_id and r.kind == :shortlist,
        where: u.user_state == :active,
        select: u
      )
      |> exclude_hidden(user_id)

    paginate_relationship_users(base, page, per_page)
  end

  @doc "Returns a bounded page of profiles whose owners liked the given user."
  def list_liked_me_users_paginated(user_id, opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> normalize_positive(1)
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> normalize_per_page()

    base =
      from(u in User,
        join: r in Relationship,
        on: r.actor_id == u.id,
        where: r.target_id == ^user_id and r.kind == :like,
        where: u.user_state == :active,
        select: u
      )
      |> exclude_hidden(user_id)

    paginate_relationship_users(base, page, per_page)
  end

  @doc """
  Returns viewer-relative flags for up to one page of profiles.

  The result is a map keyed by target user id so list endpoints can serialize
  cards without issuing one query per card.
  """
  def relationship_flags(_viewer_id, []), do: %{}

  def relationship_flags(viewer_id, target_ids) do
    ids =
      target_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    empty =
      Map.new(ids, fn id ->
        {id,
         %{
           is_liked: false,
           is_shortlisted: false,
           is_matched: false,
           is_blocked: false,
           is_muted: false
         }}
      end)

    rows =
      Repo.all(
        from(r in Relationship,
          where:
            r.actor_id == ^viewer_id and r.target_id in ^ids and
              r.kind in [:like, :shortlist, :match, :block, :mute],
          select: {r.target_id, r.kind}
        )
      )

    Enum.reduce(rows, empty, fn {target_id, kind}, acc ->
      flag =
        case kind do
          :like -> :is_liked
          :shortlist -> :is_shortlisted
          :match -> :is_matched
          :block -> :is_blocked
          :mute -> :is_muted
        end

      Map.update!(acc, target_id, fn flags -> Map.put(flags, flag, true) end)
    end)
  end

  defp paginate_relationship_users(base, page, per_page) do
    total = Repo.aggregate(base, :count, :id)

    users =
      base
      |> order_by([_u, r], desc: r.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      users: users,
      pagination: %{
        page: page,
        per_page: per_page,
        total: total,
        total_pages: total_pages(total, per_page),
        has_next_page: page < total_pages(total, per_page)
      }
    }
  end

  # Runs inside the relationship transaction. Every write here is atomic with
  # the originating like: if notification creation fails, the like rolls back.
  defp maybe_create_notifications(actor, target, :like) do
    if mutual_like?(actor.id, target.id) do
      create_match_rows(actor, target)
      create_mutual_match_notifications(actor, target)
    else
      create_like_notification(actor, target)
    end
  end

  defp maybe_create_notifications(_actor, _target, _kind), do: []

  defp mutual_like?(actor_id, target_id) do
    Repo.exists?(
      from(r in Relationship,
        where:
          r.actor_id == ^target_id and r.target_id == ^actor_id and
            r.kind == :like
      )
    )
  end

  defp create_match_rows(actor, target) do
    {:ok, _match, _} = get_or_insert(actor.id, target.id, :match)
    {:ok, _match, _} = get_or_insert(target.id, actor.id, :match)
    :ok
  end

  defp create_like_notification(actor, target) do
    {:ok, notification} =
      Notifications.insert_notification(%{
        user_id: target.id,
        actor_id: actor.id,
        type: :profile_like,
        title: "Someone liked your profile",
        body: "A nearby member is interested. Open discovery to see who.",
        metadata: %{
          "sender_id" => actor.id,
          "sender_handle" => actor.user_handle || actor.first_name,
          "sender_shortid" => actor.shortid
        }
      })

    [notification]
  end

  defp create_mutual_match_notifications(actor, target) do
    for {owner, other} <- [{actor, target}, {target, actor}] do
      {:ok, notification} =
        Notifications.insert_notification(%{
          user_id: owner.id,
          actor_id: other.id,
          type: :mutual_match,
          title: "It's a match!",
          body: "You and #{other.first_name} liked each other.",
          metadata: %{
            "match_id" => other.id,
            "match_handle" => other.user_handle || other.first_name,
            "match_shortid" => other.shortid
          }
        })

      notification
    end
  end

  defp get_or_insert(actor_id, target_id, kind) do
    case Repo.get_by(Relationship, actor_id: actor_id, target_id: target_id, kind: kind) do
      %Relationship{} = relationship ->
        {:ok, relationship, false}

      nil ->
        %Relationship{}
        |> Relationship.changeset(%{
          actor_id: actor_id,
          target_id: target_id,
          kind: kind
        })
        |> Repo.insert()
        |> case do
          {:ok, relationship} ->
            {:ok, relationship, true}

          {:error, %Ecto.Changeset{} = changeset} ->
            # Two simultaneous likes can race past the get_by/1 check. The
            # unique index wins; treat the loser as an idempotent replay.
            if Keyword.has_key?(changeset.errors, :actor_id) do
              {:ok,
               Repo.get_by!(Relationship, actor_id: actor_id, target_id: target_id, kind: kind),
               false}
            else
              {:error, changeset}
            end
        end
    end
  end

  defp prepare_relationship_rows(actor_id, target_id, :block) do
    for kind <- @kinds, kind != :block do
      delete_pair(actor_id, target_id, kind)
      delete_pair(target_id, actor_id, kind)
    end

    :ok
  end

  defp prepare_relationship_rows(actor_id, target_id, :mute) do
    delete_pair(actor_id, target_id, :like)
    delete_pair(actor_id, target_id, :match)
    delete_pair(target_id, actor_id, :match)
    :ok
  end

  defp prepare_relationship_rows(_actor_id, _target_id, _kind), do: :ok

  defp delete_pair(actor_id, target_id, kind) do
    Repo.delete_all(
      from(r in Relationship,
        where: r.actor_id == ^actor_id and r.target_id == ^target_id and r.kind == ^kind
      )
    )
  end

  defp users_for(user_id, kind) do
    Repo.all(
      from(u in User,
        join: r in Relationship,
        on: r.target_id == u.id,
        where: r.actor_id == ^user_id and r.kind == ^kind,
        where: u.user_state == :active,
        order_by: [desc: r.inserted_at],
        select: u
      )
    )
  end

  defp ensure_not_hidden(actor_id, target_id, kind)
       when kind in [:like, :dislike, :shortlist] do
    if hidden?(actor_id, target_id), do: {:error, :blocked}, else: :ok
  end

  defp ensure_not_hidden(_actor_id, _target_id, _kind), do: :ok

  defp ids_for(user_id, kind) do
    Repo.all(
      from(r in Relationship,
        where: r.actor_id == ^user_id and r.kind == ^kind,
        select: r.target_id
      )
    )
  end

  defp fetch_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :target_not_found}
      user -> {:ok, user}
    end
  end

  defp ensure_not_self(actor_id, target_id) do
    if actor_id == target_id, do: {:error, :self_relationship}, else: :ok
  end

  defp cast_kind(kind) when kind in @kinds, do: {:ok, kind}

  defp cast_kind(kind) when is_binary(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :invalid_kind}
      kind -> {:ok, kind}
    end
  end

  defp cast_kind(_kind), do: {:error, :invalid_kind}

  defp normalize_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :target_not_found}
    end
  end

  defp normalize_id(_id), do: {:error, :target_not_found}

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive(_value, default), do: default

  defp normalize_per_page(value) do
    value
    |> normalize_positive(@default_per_page)
    |> min(@max_per_page)
  end

  defp total_pages(0, _per_page), do: 0
  defp total_pages(total, per_page), do: div(total + per_page - 1, per_page)
end
