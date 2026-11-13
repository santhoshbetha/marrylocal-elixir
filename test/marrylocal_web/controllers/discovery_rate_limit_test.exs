defmodule MarrylocalWeb.DiscoveryRateLimitTest do
  use MarrylocalWeb.ConnCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.RateLimit

  @limit 15
  @window_ms 30_000

  test "limits authenticated discovery requests to 15 per 30 seconds" do
    user = user_fixture(%{city: "Delhi"})
    token = Accounts.generate_user_session_token(user)

    first_body =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/discovery", search_mode: "full_city")
      |> json_response(200)
      |> Map.fetch!("data")

    assert first_body["search_mode"] == "full_city"
    assert Map.has_key?(first_body, "has_more")
    assert Map.has_key?(first_body, "next_cursor")

    # Use a fresh member for the limit assertion. This isolates the direct
    # rate-limit fills from the first HTTP request, which may or may not have
    # consumed the same bucket depending on timing.
    limited_user = user_fixture(%{city: "Delhi"})
    limited_token = Accounts.generate_user_session_token(limited_user)
    key = "discovery:user:#{limited_user.id}"

    for _request_number <- 1..@limit do
      assert {:ok, false} = RateLimit.check_rate(key, @limit, @window_ms)
    end

    limited =
      build_conn()
      |> put_req_header("authorization", "Bearer #{limited_token}")
      |> get(~p"/api/v1/profiles/discovery", search_mode: "full_city")

    assert json_response(limited, 429) == %{
             "status" => "error",
             "message" => "Too many search requests. Please wait a moment before trying again."
           }
  end
end
