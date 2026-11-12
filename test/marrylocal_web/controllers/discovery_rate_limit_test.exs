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

    request = fn ->
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/profiles/discovery", search_mode: "full_city")
    end

    first_body = json_response(request.(), 200)["data"]
    assert first_body["search_mode"] == "full_city"
    assert Map.has_key?(first_body, "has_more")
    assert Map.has_key?(first_body, "next_cursor")

    # The first HTTP request consumed one slot. Fill the remaining 14 slots
    # directly so the test proves the plug/pipeline without 30 seconds of DB work.
    key = "discovery:user:#{user.id}"

    for _request_number <- 2..@limit do
      assert {:ok, false} = RateLimit.check_rate(key, @limit, @window_ms)
    end

    limited = request.()

    assert json_response(limited, 429) == %{
             "status" => "error",
             "message" => "Too many search requests. Please wait a moment before trying again."
           }
  end
end
