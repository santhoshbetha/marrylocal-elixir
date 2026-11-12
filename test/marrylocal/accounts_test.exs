defmodule Marrylocal.AccountsTest do
  use Marrylocal.DataCase

  alias Marrylocal.Accounts

  import Marrylocal.AccountsFixtures
  alias Marrylocal.Accounts.{User, UserToken}
  alias Marrylocal.Repo

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(-1)
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end

    test "persists age only and discards the raw birthday" do
      {:ok, user} =
        Accounts.register_user(valid_user_attributes(date_of_birth: ~D[1995-01-01]))

      assert is_integer(user.age)
      assert user.age >= 18
      assert is_nil(user.date_of_birth)
    end

    test "locks in the configured annual service fee at registration" do
      previous = Application.get_env(:marrylocal, :billing)

      on_exit(fn ->
        if previous do
          Application.put_env(:marrylocal, :billing, previous)
        else
          Application.delete_env(:marrylocal, :billing)
        end
      end)

      Application.put_env(:marrylocal, :billing, default_annual_fee_inr: 750)

      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert user.accepted_one_time_fees_amount == 750
    end

    test "defaults the annual service fee to 500 when billing config is absent" do
      previous = Application.get_env(:marrylocal, :billing)

      on_exit(fn ->
        if previous do
          Application.put_env(:marrylocal, :billing, previous)
        else
          Application.delete_env(:marrylocal, :billing)
        end
      end)

      Application.delete_env(:marrylocal, :billing)

      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert user.accepted_one_time_fees_amount == 500
    end

    test "generates an eight-character referral code" do
      {:ok, user} = Accounts.register_user(valid_user_attributes())

      assert user.referral_code =~ ~r/^ML[A-Z0-9]{6}$/
      assert String.length(user.referral_code) == 8
      assert user.referral_credits_count == 0
    end

    test "links a valid referral and credits the referrer atomically" do
      referrer = user_fixture()

      {:ok, referred} =
        Accounts.register_user(valid_user_attributes(referred_by_code: referrer.referral_code))

      assert referred.referred_by_id == referrer.id
      assert Repo.get!(User, referrer.id).referral_credits_count == 1

      summary = Accounts.referral_summary(referrer.id)

      assert summary.referral_code == referrer.referral_code
      assert summary.credit_value_inr == 50
      assert [%{id: referred_id, credit_value_inr: 50}] = summary.referrals
      assert referred_id == referred.id
    end

    test "rejects an unknown referral code" do
      assert {:error, :invalid_referral_code} =
               Accounts.register_user(valid_user_attributes(referred_by_code: "BADCODE1"))
    end
  end

  describe "coordinate privacy" do
    test "fuzzes persisted coordinates within the 5km bounding box" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_coordinates(user, %{
                 latitude: 12.9716,
                 longitude: 77.5946
               })

      assert_in_delta updated.latitude, 12.9716, 0.045
      assert_in_delta updated.longitude, 77.5946, 0.045
      refute updated.latitude == 12.9716 and updated.longitude == 77.5946
      assert %Geo.Point{srid: 4326} = updated.location
    end
  end

  describe "terms acceptance" do
    test "persists the accepted flag through the profile changeset" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_profile_and_location(user, %{terms_accepted: true})

      assert updated.terms_accepted == true
    end
  end

  describe "one-time core profile edits" do
    test "the first core edit sets the flag atomically" do
      user = user_fixture()
      refute user.core_details_edited

      assert {:ok, updated} =
               Accounts.update_profile_and_location(user, %{"first_name" => "Corrected"})

      assert updated.first_name == "Corrected"
      assert updated.core_details_edited
    end

    test "a second core edit is rejected once the flag is set" do
      user = user_fixture()

      assert {:ok, _updated} =
               Accounts.update_profile_and_location(user, %{"community" => "Brahmin Iyer"})

      user = Repo.get!(User, user.id)

      assert {:error, :core_details_locked} =
               Accounts.update_profile_and_location(user, %{"language" => "Tamil"})
    end

    test "education, job status, and religion remain editable after locking" do
      user = user_fixture()

      assert {:ok, _updated} =
               Accounts.update_profile_and_location(user, %{"last_name" => "Corrected"})

      user = Repo.get!(User, user.id)

      assert {:ok, updated} =
               Accounts.update_profile_and_location(user, %{
                 "education_level" => "Masters level",
                 "job_status" => true,
                 "religion" => "Hindu"
               })

      assert updated.education_level == :"Masters level"
      assert updated.job_status
      assert updated.religion == "Hindu"
      assert updated.core_details_edited
    end

    test "resubmitting unchanged core values does not consume the edit" do
      user = user_fixture()

      assert {:ok, unchanged} =
               Accounts.update_profile_and_location(user, %{
                 "first_name" => user.first_name,
                 "last_name" => user.last_name
               })

      refute unchanged.core_details_edited

      assert {:ok, updated} =
               Accounts.update_profile_and_location(unchanged, %{"first_name" => "Corrected"})

      assert updated.core_details_edited
    end
  end

  describe "subscription activation" do
    test "computes interval dates and structured feature columns on the server" do
      user = user_fixture()
      start_date = ~D[2026-11-10]

      assert {:ok, %{user: updated, subscription: subscription}} =
               Accounts.activate_subscription(
                 user.id,
                 %{
                   "community_search" => true,
                   "location2" => %{"city" => "Mumbai", "state" => "Maharashtra"}
                 },
                 start_date
               )

      assert subscription.status == "active"
      assert subscription.info["start_date"] == "2026-11-10"
      assert subscription.info["end_date"] == "2026-12-10"
      assert updated.community_search_active == true
      assert updated.multi_location_slots["location2"]["city"] == "Mumbai"
    end

    test "does not grant or retain the retired full-city addon entitlement" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(addons: %{"fullcitySearch" => true})
        |> Repo.update!()

      assert {:ok, %{user: updated}} =
               Accounts.activate_subscription(
                 user.id,
                 %{"full_city_search" => true, "community_search" => true},
                 ~D[2026-11-10]
               )

      refute Map.has_key?(updated.addons || %{}, "fullcitySearch")
      assert updated.community_search_active == true
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, hashed_token} = UserToken.hash_session_token(token)
      assert user_token = Repo.get_by(UserToken, token: hashed_token)
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      {:ok, hashed_token} = UserToken.hash_session_token(token)
      assert user_token = Repo.get_by(UserToken, token: hashed_token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil
      refute Repo.get_by(UserToken, token: token)

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      {:ok, hashed_token} = UserToken.hash_session_token(token)
      assert user_token = Repo.get_by(UserToken, token: hashed_token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, hashed_token} = UserToken.hash_session_token(token)
      assert user_token = Repo.get_by(UserToken, token: hashed_token)
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
