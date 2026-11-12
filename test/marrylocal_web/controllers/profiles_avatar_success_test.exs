defmodule MarrylocalWeb.ProfilesAvatarSuccessTest do
  use MarrylocalWeb.ConnCase, async: false

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo
  alias Marrylocal.TestSupport.SuccessAvatarStorage

  setup %{conn: conn} do
    previous_storage = Application.get_env(:waffle, :storage)
    Application.put_env(:waffle, :storage, SuccessAvatarStorage)

    on_exit(fn -> Application.put_env(:waffle, :storage, previous_storage) end)

    user = user_fixture()
    token = Accounts.generate_user_session_token(user)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    upload_path =
      Path.join(
        System.tmp_dir!(),
        "success-avatar-#{System.unique_integer([:positive])}.png"
      )

    File.write!(
      upload_path,
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAAWSURBVChTY1CoyPuPDzOgC6Dj4aEAAFeGgUEU0rJwAAAAAElFTkSuQmCC"
      )
    )

    on_exit(fn -> File.rm(upload_path) end)

    {:ok, conn: conn, user: user, upload_path: upload_path}
  end

  test "stores the avatar under the user scope with a single extension", %{
    conn: conn,
    user: user,
    upload_path: path
  } do
    upload = %Plug.Upload{
      path: path,
      filename: "portrait.png",
      content_type: "image/png"
    }

    conn = post(conn, ~p"/api/v1/profiles/me/avatar", %{"avatar" => upload})

    body = json_response(conn, 201)
    avatar_url = body["data"]["avatar_url"]

    assert avatar_url =~ "/uploads/users/#{user.id}/avatar/original.png"
    refute avatar_url =~ "original.png.png"

    stored = Repo.get!(User, user.id).avatar

    # Waffle.Ecto persists the source file name; `Avatar.filename/2` maps it to
    # `original.<ext>` when the storage key and public URL are built.
    assert stored.file_name == "portrait.png"
    assert stored.updated_at
  end

  test "uploads a photo into the requested slot without touching the avatar", %{
    conn: conn,
    user: user,
    upload_path: path
  } do
    conn =
      post(conn, ~p"/api/v1/profiles/me/avatar", %{
        "avatar" => upload_struct(path, "slot-photo.png"),
        "slot_index" => "3"
      })

    body = json_response(conn, 201)
    image_url = body["data"]["image_url"]

    assert body["data"]["slot_index"] == 3
    assert image_url =~ "/uploads/users/#{user.id}/photos/3/original.png"

    refreshed = Repo.get!(User, user.id)

    assert refreshed.avatar == nil
    assert refreshed.images == [nil, nil, nil, image_url]
  end

  test "keeps previously filled slots when another slot is uploaded", %{
    conn: conn,
    user: user,
    upload_path: path
  } do
    first_url =
      conn
      |> post(~p"/api/v1/profiles/me/avatar", %{
        "avatar" => upload_struct(path, "first.png"),
        "slot_index" => "0"
      })
      |> json_response(201)
      |> get_in(["data", "image_url"])

    third_url =
      conn
      |> post(~p"/api/v1/profiles/me/avatar", %{
        "avatar" => upload_struct(path, "third.png"),
        "slot_index" => "2"
      })
      |> json_response(201)
      |> get_in(["data", "image_url"])

    assert Repo.get!(User, user.id).images == [first_url, nil, third_url]
  end

  test "rejects an out-of-range slot index", %{
    conn: conn,
    user: user,
    upload_path: path
  } do
    conn =
      post(conn, ~p"/api/v1/profiles/me/avatar", %{
        "avatar" => upload_struct(path, "photo.png"),
        "slot_index" => "10"
      })

    body = json_response(conn, 422)

    assert body["code"] == "invalid_slot_index"
    assert Repo.get!(User, user.id).images == []
  end

  test "deletes one slot while preserving the surrounding indices", %{
    conn: conn,
    user: user,
    upload_path: path
  } do
    urls =
      for slot <- [0, 1, 2] do
        conn
        |> post(~p"/api/v1/profiles/me/avatar", %{
          "avatar" => upload_struct(path, "slot-#{slot}.png"),
          "slot_index" => Integer.to_string(slot)
        })
        |> json_response(201)
        |> get_in(["data", "image_url"])
      end

    [first_url, _second_url, third_url] = urls

    conn = delete(conn, ~p"/api/v1/profiles/me/photos/1")

    body = json_response(conn, 200)

    assert body["data"]["slot_index"] == 1
    assert Repo.get!(User, user.id).images == [first_url, nil, third_url]
  end

  defp upload_struct(path, filename) do
    %Plug.Upload{path: path, filename: filename, content_type: "image/png"}
  end
end
