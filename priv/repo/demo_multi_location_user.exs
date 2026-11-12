alias Marrylocal.{Billing, Geo, Repo}
alias Marrylocal.Accounts.User

email = "multilocation.demo@marrylocal.test"
password = "Password123!"
now = DateTime.utc_now() |> DateTime.truncate(:second)

user = Repo.get_by(User, email: email)

user =
  if user do
    user
    |> Ecto.Changeset.change(hashed_password: Pbkdf2.hash_pwd_salt(password))
    |> Repo.update!()
  else
    %User{}
    |> User.registration_changeset(%{
      email: email,
      phone_number: "9000000099",
      first_name: "Multi",
      last_name: "Location",
      date_of_birth: ~D[1994-05-15],
      gender: "Male",
      user_handle: "multiloc_demo",
      password: password,
      password_confirmation: password,
      city: "Hyderabad",
      state: "Telangana",
      language: "Telugu",
      religion: "Hindu",
      community: "Kamma",
      education_level: "Bachelors level",
      economic_status: "Middleclass",
      job_status: true
    })
    |> Repo.insert!()
  end

location_2_purchased_at = DateTime.add(now, -10, :day)
location_2_expires_at = DateTime.add(now, 20, :day)
location_2_last_changed_at = DateTime.add(now, -10, :day)
location_3_purchased_at = DateTime.add(now, -40, :day)
location_3_expires_at = DateTime.add(now, 25, :day)
location_3_last_changed_at = DateTime.add(now, -40, :day)

user =
  user
  |> Ecto.Changeset.change(%{
    confirmed_at: now,
    email_verified: true,
    terms_accepted: true,
    user_state: :active,
    is_beta_tester: true,
    community_search_active: true,
    max_search_distance: 300,
    onetime_fees_paid: true,
    onetime_fees_required: false,
    accepted_one_time_fees_amount: 500,
    date_of_last_payment: Date.utc_today(),
    last_payment_at: now,
    latitude: 17.3850,
    longitude: 78.4867,
    location: Geo.point(17.3850, 78.4867),
    location_2_state: "Karnataka",
    location_2_city: "Bangalore",
    location_2_geom: Geo.point(12.9716, 77.5946),
    location_2_purchased_at: location_2_purchased_at,
    location_2_expires_at: location_2_expires_at,
    location_2_last_changed_at: location_2_last_changed_at,
    location_3_state: "Tamil Nadu",
    location_3_city: "Chennai",
    location_3_geom: Geo.point(13.0827, 80.2707),
    location_3_purchased_at: location_3_purchased_at,
    location_3_expires_at: location_3_expires_at,
    location_3_last_changed_at: location_3_last_changed_at,
    multi_location_slots: %{
      "location2" => %{
        "city" => "Bangalore",
        "state" => "Karnataka",
        "lat" => 12.9716,
        "lng" => 77.5946
      },
      "location3" => %{
        "city" => "Chennai",
        "state" => "Tamil Nadu",
        "lat" => 13.0827,
        "lng" => 80.2707
      }
    },
    addons: %{
      "communitySearch" => true,
      "location2" => %{"city2" => "Bangalore", "state2" => "Karnataka"},
      "location3" => %{"city3" => "Chennai", "state3" => "Tamil Nadu"}
    }
  })
  |> Repo.update!()

existing_invoice_types =
  Billing.list_invoices(user.id)
  |> Enum.map(& &1.item_type)

unless "addon_location_2" in existing_invoice_types do
  Billing.create_itemized_invoice(user, "location2",
    period_start: location_2_purchased_at,
    period_end: location_2_expires_at,
    payment_reference: "DEMO-LOCATION-2"
  )
end

unless "addon_location_3" in existing_invoice_types do
  Billing.create_itemized_invoice(user, "location3",
    period_start: location_3_purchased_at,
    period_end: location_3_expires_at,
    payment_reference: "DEMO-LOCATION-3"
  )
end

unless "annual_fee" in existing_invoice_types do
  Billing.create_annual_fee_invoice(user,
    base_amount_inr: 500,
    period_start: DateTime.add(now, -30, :day),
    period_end: DateTime.add(now, 335, :day),
    payment_reference: "DEMO-ANNUAL-FEE"
  )
end

IO.puts("""
Multi-location demo account ready
Email:    #{email}
Password: #{password}

Locations:
- Primary:    Hyderabad, Telangana
- Location 2: Bangalore, Karnataka
- Location 3: Chennai, Tamil Nadu

Demo states:
- Location 2 cooldown is active (locked badge).
- Location 3 cooldown is eligible (changeable).
- Discovery location selector shows Primary / Location 2 / Location 3.
- Settings shows addon cards and itemized invoices.
""")
