defmodule Marrylocal.AntiSpamKycTest do
  use Marrylocal.DataCase

  import Marrylocal.AccountsFixtures

  alias Marrylocal.Accounts
  alias Marrylocal.Accounts.SignupGuard

  test "rejects disposable email domains" do
    assert {:error, changeset} =
             Accounts.register_user(
               valid_user_attributes(email: "spam@mailinator.com", phone_number: "9876543210")
             )

    assert changeset.errors[:email]
  end

  test "normalizes +91 phone numbers to ten digits and enforces uniqueness" do
    phone =
      "98765#{System.unique_integer([:positive]) |> rem(100_000) |> Integer.to_string() |> String.pad_leading(5, "0")}"

    assert {:ok, user} =
             Accounts.register_user(
               valid_user_attributes(
                 email: "phone.one.#{System.unique_integer([:positive])}@example.com",
                 phone_number: "+91 #{phone}"
               )
             )

    assert user.phone_number == phone

    assert {:error, changeset} =
             Accounts.register_user(
               valid_user_attributes(
                 email: "phone.two.#{System.unique_integer([:positive])}@example.com",
                 phone_number: phone
               )
             )

    assert changeset.errors[:phone_number]
  end

  test "normalizes document numbers and creates stable salted hashes" do
    first = SignupGuard.identity_hash("passport", " p-123 4567 ")
    second = SignupGuard.identity_hash("PASSPORT", "P1234567")
    third = SignupGuard.identity_hash("license", "P1234567")

    assert first == second
    refute first == third
    assert String.length(first) == 64
  end

  test "rejects a photo hash already active on another user" do
    user_one = user_fixture()
    user_two = user_fixture()
    hash = String.duplicate("a", 64)

    assert {:ok, _} = Accounts.claim_photo_hash(user_one, hash, 0)
    assert Accounts.photo_hash_claimed?(hash, user_two.id)
    refute Accounts.photo_hash_claimed?(hash, user_one.id)
    assert {:error, :duplicate_photo} = Accounts.claim_photo_hash(user_two, hash, 0)
  end
end
