defmodule Marrylocal.RegistrationJobStatusTest do
  use Marrylocal.DataCase, async: true

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts

  test "registration persists job_status and the other profile metrics" do
    attrs =
      valid_user_attributes(%{
        job_status: true,
        education_level: "Bachelors level",
        economic_status: "Middleclass"
      })

    assert {:ok, user} = Accounts.register_user(attrs)

    assert user.job_status == true
    assert user.education_level == :"Bachelors level"
    assert user.economic_status == :Middleclass
  end

  test "profile updates persist job_status later" do
    user = user_fixture()

    assert {:ok, updated} =
             Accounts.update_profile_and_location(user, %{"job_status" => true})

    assert updated.job_status == true
  end
end
