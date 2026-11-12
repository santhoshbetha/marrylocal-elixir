defmodule MarrylocalWeb.RelationshipsControllerTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Relationships

  setup %{conn: conn} do
    viewer = user_fixture()
    admirer = user_fixture()
    saved = user_fixture()

    {:ok, _} = Relationships.create_relationship(admirer.id, viewer.id, :like)
    {:ok, _} = Relationships.create_relationship(viewer.id, saved.id, :shortlist)

    token = Accounts.generate_user_session_token(viewer)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, viewer: viewer, admirer: admirer, saved: saved}
  end

  describe "GET /api/v1/relationships/liked-me" do
    test "returns profiles whose owners liked the viewer", %{conn: conn, admirer: admirer} do
      conn = get(conn, ~p"/api/v1/relationships/liked-me")

      response = json_response(conn, 200)
      users = response["data"]["users"]

      assert response["data"]["kind"] == "liked_me"
      assert Enum.any?(users, &(&1["id"] == admirer.id))
      assert Enum.all?(users, &(&1["is_liked"] == false))
    end
  end

  describe "GET /api/v1/relationships/shortlisted" do
    test "returns shortlisted profiles with viewer-relative flags", %{
      conn: conn,
      saved: saved
    } do
      conn = get(conn, ~p"/api/v1/relationships/shortlisted")

      response = json_response(conn, 200)
      users = response["data"]["users"]

      assert response["data"]["kind"] == "shortlisted"

      assert [%{"id" => id, "is_shortlisted" => true}] =
               Enum.filter(users, &(&1["id"] == saved.id))

      assert id == saved.id
    end
  end

  describe "block and mute relationships" do
    test "blocks hide both users, remove incoming likes, and expose the blocked list", %{
      conn: conn,
      viewer: viewer,
      admirer: admirer
    } do
      conn =
        post(conn, ~p"/api/v1/relationships", %{"kind" => "block", "target_id" => admirer.id})

      assert json_response(conn, 201)["data"]["relationship"]["kind"] == "block"

      assert Relationships.blocked?(viewer.id, admirer.id)
      assert Relationships.hidden?(viewer.id, admirer.id)

      blocked_conn = get(conn, ~p"/api/v1/relationships/blocked")
      blocked = json_response(blocked_conn, 200)["data"]["users"]

      assert Enum.any?(blocked, &(&1["id"] == admirer.id))

      liked_me = Relationships.list_liked_me_users_paginated(viewer.id)
      assert liked_me.pagination.total == 0

      blocked_like =
        post(conn, ~p"/api/v1/relationships", %{"kind" => "like", "target_id" => admirer.id})

      assert json_response(blocked_like, 403)["status"] == "error"
    end

    test "mutes hide both users, remove the actor's outgoing like, and expose the muted list", %{
      conn: conn,
      viewer: viewer,
      saved: saved
    } do
      {:ok, _} = Relationships.create_relationship(viewer.id, saved.id, :like)

      conn = post(conn, ~p"/api/v1/relationships", %{"kind" => "mute", "target_id" => saved.id})
      assert json_response(conn, 201)["data"]["relationship"]["kind"] == "mute"

      assert Relationships.hidden?(viewer.id, saved.id)
      refute saved.id in Relationships.summary(viewer.id).likes

      muted_conn = get(conn, ~p"/api/v1/relationships/muted")
      muted = json_response(muted_conn, 200)["data"]["users"]

      assert Enum.any?(muted, &(&1["id"] == saved.id))
    end

    test "returns combined moderated lists", %{
      conn: conn,
      viewer: viewer,
      admirer: admirer,
      saved: saved
    } do
      {:ok, _} = Relationships.create_relationship(viewer.id, admirer.id, :block)
      {:ok, _} = Relationships.create_relationship(viewer.id, saved.id, :mute)

      conn = get(conn, ~p"/api/v1/relationships/moderated")
      data = json_response(conn, 200)["data"]

      assert data["kind"] == "moderated"
      assert data["counts"]["blocked"] >= 1
      assert data["counts"]["muted"] >= 1
      assert Enum.any?(data["blocked"], &(&1["id"] == admirer.id))
      assert Enum.any?(data["muted"], &(&1["id"] == saved.id))
    end
  end
end
