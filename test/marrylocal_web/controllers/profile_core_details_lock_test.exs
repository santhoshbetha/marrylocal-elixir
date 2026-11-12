defmodule MarrylocalWeb.ProfileCoreDetailsLockTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  test "core details can only be edited once", %{conn: conn} do
    user = user_fixture() |> set_password()

    login_conn =
      post(conn, ~p"/api/v1/auth/login", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    token = json_response(login_conn, 200)["data"]["token"]

    patch_profile = fn body ->
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> patch(~p"/api/v1/profiles/me", body)
    end

    first_conn =
      patch_profile.(%{"first_name" => "Corrected", "education_level" => "Masters level"})

    first_body = json_response(first_conn, 200)
    assert first_body["data"]["profile"]["first_name"] == "Corrected"
    assert first_body["data"]["profile"]["core_details_edited"] == true

    locked_conn = patch_profile.(%{"language" => "Tamil"})

    locked_body = json_response(locked_conn, 422)
    assert locked_body["code"] == "core_details_locked"

    assert locked_body["message"] ==
             "Name, language, and community can only be updated once."

    allowed_conn =
      patch_profile.(%{
        "education_level" => "Bachelors level",
        "job_status" => true,
        "religion" => "Hindu"
      })

    allowed_body = json_response(allowed_conn, 200)
    assert allowed_body["data"]["profile"]["education_level"] == "Bachelors level"
    assert allowed_body["data"]["profile"]["job_status"] == true
    assert allowed_body["data"]["profile"]["religion"] == "Hindu"
    assert allowed_body["data"]["profile"]["core_details_edited"] == true
  end
end
