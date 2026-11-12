defmodule MarrylocalWeb.UserJSON do
  @moduledoc """
  Serializers for the authenticated account, public discovery cards, and the
  legacy shortlist payload.

  Public profiles never expose email, phone, Aadhaar, or exact coordinates.
  Distance is attached by the discovery context as a rounded kilometre value.
  """

  alias Marrylocal.Accounts.User
  alias Marrylocal.Uploaders.Avatar
  alias Marrylocal.Features

  def auth(user) do
    %{
      id: user.id,
      email: user.email,
      user_handle: user.user_handle,
      shortid: user.shortid,
      first_name: user.first_name,
      last_name: user.last_name,
      role: user.role,
      user_state: user.user_state,
      confirmed_at: user.confirmed_at,
      email_verified: user.email_verified || not is_nil(user.confirmed_at),
      terms_accepted: user.terms_accepted,
      accepted_one_time_fees_amount: user.accepted_one_time_fees_amount,
      images: user.images,
      avatar_url: avatar_url(user),
      around_user_count: user.around_user_count,
      force_verification_required: user.force_verification_required,
      payment_enforcement_active: Features.payment_enforcement_active?(user),
      effective_payment_required: Features.payment_enforcement_active?(user),
      onboarding_complete: onboarding_complete?(user)
    }
    |> Map.merge(location_switcher_fields(user))
  end

  def profile(user) do
    public_profile(user)
    |> Map.put(:last_name, user.last_name)
    |> Map.merge(%{
      email: user.email,
      role: user.role,
      phone_number: user.phone_number,
      show_phone: user.show_phone,
      show_facebook: user.show_facebook,
      show_instagram: user.show_instagram,
      show_community: user.show_community,
      show_in_other_religion_people_search: user.show_in_other_religion_people_search,
      hide_last_name: user.hide_last_name,
      restrict_lookup_to_200km: user.restrict_lookup_to_200km,
      allow_email_search: user.allow_email_search,
      allow_phone_search: user.allow_phone_search,
      allow_handle_search: user.allow_handle_search,
      is_beta_tester: user.is_beta_tester,
      community_search_enabled: Features.community_search_enabled?(user),
      community_search_active: user.community_search_active,
      multi_location_slots: legacy_location_slots(user),
      max_search_distance: user.max_search_distance,
      latitude: user.latitude,
      longitude: user.longitude,
      default_coordinates_set: user.default_coordinates_set,
      user_coordinates_set: user.user_coordinates_set,
      date_of_location: user.date_of_location,
      allow_location_change_at: location_change_allowed_at(user),
      location_change_locked: location_change_locked?(user),
      date_of_coordinates: user.date_of_coordinates,
      allow_coords_change_at: coords_change_allowed_at(user),
      coords_change_locked: coords_change_locked?(user),
      terms_accepted: user.terms_accepted,
      core_details_edited: user.core_details_edited,
      onetime_fees_paid: user.onetime_fees_paid,
      onetime_fees_required: user.onetime_fees_required,
      accepted_one_time_fees_amount: user.accepted_one_time_fees_amount,
      accepted_years_initial_term: user.accepted_years_initial_term,
      referral_credits_count: user.referral_credits_count,
      force_verification_required: user.force_verification_required,
      payment_enforcement_active: Features.payment_enforcement_active?(user),
      effective_payment_required: Features.payment_enforcement_active?(user),
      date_of_last_payment: user.date_of_last_payment,
      last_payment_at: user.last_payment_at,
      last_fee_paid_at: user.last_payment_at,
      around_user_count: user.around_user_count,
      updated_at: user.updated_at,
      addons: user.addons || %{},
      settings: %{
        "show_phone" => user.show_phone,
        "show_facebook" => user.show_facebook,
        "show_instagram" => user.show_instagram,
        "show_community" => user.show_community
      }
    })
    |> Map.merge(location_switcher_fields(user))
    |> Map.merge(location_slot_fields(user))
  end

  def public_profile(user) do
    %{
      id: user.id,
      shortid: user.shortid,
      user_handle: user.user_handle,
      first_name: user.first_name,
      last_name: display_last_name(user),
      age: user.age,
      gender: user.gender,
      city: user.city,
      state: user.state,
      language: user.language,
      religion: user.religion,
      community: if(user.show_community, do: user.community, else: nil),
      caste: user.caste,
      bio: user.bio,
      education_level: enum_value(user.education_level),
      economic_status: enum_value(user.economic_status),
      job_status: user.job_status,
      verified: user.aadhar_verified || user.passport_verified || user.license_verified || false,
      images: user.images,
      avatar_url: avatar_url(user),
      is_mutual: Map.get(user, :is_mutual, false),
      is_online: MarrylocalWeb.Presence.online?(user.id),
      last_login_at: user.last_login_at || user.time_of_login,
      last_seen_at: user.last_seen_at,
      phone: if(user.show_phone, do: user.phone_number, else: nil),
      social: %{
        facebook: if(user.show_facebook, do: user.facebook, else: nil),
        instagram: if(user.show_instagram, do: user.instagram, else: nil)
      }
    }
  end

  @doc "Attaches a rounded distance in kilometres to a public card."
  def with_distance(profile, distance_km) when is_number(distance_km) do
    Map.put(profile, :distance_km, Float.round(distance_km * 1.0, 1))
  end

  def with_distance(profile, _distance_km), do: Map.put(profile, :distance_km, nil)

  @doc "Legacy shortlist payload retained for the existing mobile client."
  def data(user) do
    ref_count = Enum.count(user.referee_emails || [])
    discount = min(ref_count, 8) * 50
    current_fee = 500 - discount

    %{
      id: user.id,
      shortid: user.shortid,
      user_handle: user.user_handle,
      first_name: user.first_name,
      age: user.age,
      images: user.images,
      is_mutual: user.is_mutual,
      last_login_at: user.time_of_login,
      onetime_fees_required: !user.onetime_fees_paid,
      base_fee: 500,
      current_discount: discount,
      payable_amount: current_fee,
      referral_count: ref_count,
      phone: if(user.show_phone, do: user.phone_number, else: nil)
    }
  end

  defp location_switcher_fields(user) do
    %{
      location_2_active: User.location_active?(user, :location_2),
      location_2_city: user.location_2_city,
      location_2_state: user.location_2_state,
      location_2_expires_at: user.location_2_expires_at,
      location_3_active: User.location_active?(user, :location_3),
      location_3_city: user.location_3_city,
      location_3_state: user.location_3_state,
      location_3_expires_at: user.location_3_expires_at
    }
  end

  defp location_slot_fields(user) do
    slot2 = secondary_slot_json(user, :location_2, "location_2")
    slot3 = secondary_slot_json(user, :location_3, "location_3")

    Map.merge(location_switcher_fields(user), %{
      location_2_latitude: slot2.latitude,
      location_2_longitude: slot2.longitude,
      location_2_last_changed_at: slot2.last_changed_at,
      location_2_allow_change_at: slot2.allow_change_at,
      location_2_change_locked: slot2.change_locked,
      location_3_latitude: slot3.latitude,
      location_3_longitude: slot3.longitude,
      location_3_last_changed_at: slot3.last_changed_at,
      location_3_allow_change_at: slot3.allow_change_at,
      location_3_change_locked: slot3.change_locked,
      location_slots: %{
        primary: %{
          slot: "primary",
          label: "Primary Location",
          active: true,
          city: user.city,
          state: user.state,
          latitude: user.latitude,
          longitude: user.longitude
        },
        location_2: slot2,
        location_3: slot3
      }
    })
  end

  defp secondary_slot_json(user, slot, key) do
    geom = Map.get(user, String.to_existing_atom("#{key}_geom"))
    {latitude, longitude} = geom_coords(geom)
    last_changed = Map.get(user, String.to_existing_atom("#{key}_last_changed_at"))
    allow_change_at = last_changed && DateTime.add(last_changed, 30, :day)

    %{
      slot: key,
      label: if(slot == :location_2, do: "Location 2", else: "Location 3"),
      active: User.location_active?(user, slot),
      city: Map.get(user, String.to_existing_atom("#{key}_city")),
      state: Map.get(user, String.to_existing_atom("#{key}_state")),
      latitude: latitude,
      longitude: longitude,
      purchased_at: Map.get(user, String.to_existing_atom("#{key}_purchased_at")),
      expires_at: Map.get(user, String.to_existing_atom("#{key}_expires_at")),
      last_changed_at: last_changed,
      allow_change_at: allow_change_at,
      change_locked:
        allow_change_at != nil and DateTime.compare(allow_change_at, DateTime.utc_now()) == :gt
    }
  end

  defp legacy_location_slots(user) do
    %{}
    |> put_legacy_slot(
      "location2",
      user.location_2_city,
      user.location_2_state,
      user.location_2_geom
    )
    |> put_legacy_slot(
      "location3",
      user.location_3_city,
      user.location_3_state,
      user.location_3_geom
    )
  end

  defp put_legacy_slot(slots, _key, nil, _state, _geom), do: slots

  defp put_legacy_slot(slots, key, city, state, geom) do
    {latitude, longitude} = geom_coords(geom)

    Map.put(slots, key, %{
      "city" => city,
      "state" => state,
      "lat" => latitude,
      "lng" => longitude
    })
  end

  defp geom_coords(%Geo.Point{coordinates: {longitude, latitude}}) do
    {Float.round(latitude * 1.0, 6), Float.round(longitude * 1.0, 6)}
  end

  defp geom_coords(_geom), do: {nil, nil}

  defp location_change_allowed_at(%{date_of_location: nil}), do: nil

  defp location_change_allowed_at(%{date_of_location: date_of_location}) do
    DateTime.add(date_of_location, 30, :day)
  end

  defp location_change_locked?(%{date_of_location: nil}), do: false

  defp location_change_locked?(%{date_of_location: date_of_location}) do
    DateTime.compare(DateTime.add(date_of_location, 30, :day), DateTime.utc_now()) == :gt
  end

  defp coords_change_allowed_at(%{date_of_coordinates: nil}), do: nil

  defp coords_change_allowed_at(%{date_of_coordinates: date_of_coordinates}) do
    DateTime.add(date_of_coordinates, 30, :day)
  end

  defp coords_change_locked?(%{date_of_coordinates: nil}), do: false

  defp coords_change_locked?(%{date_of_coordinates: date_of_coordinates}) do
    DateTime.compare(DateTime.add(date_of_coordinates, 30, :day), DateTime.utc_now()) == :gt
  end

  defp avatar_url(%{avatar: nil}), do: nil

  defp avatar_url(%{avatar: avatar} = user) do
    Avatar.url({avatar, user})
  rescue
    _ -> nil
  end

  defp onboarding_complete?(user) do
    present?(user.first_name) and is_integer(user.age) and present?(user.city) and
      present?(user.gender)
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp display_last_name(%{hide_last_name: true} = user), do: initial_last_name(user.last_name)
  defp display_last_name(user), do: user.last_name

  defp initial_last_name(nil), do: nil
  defp initial_last_name(""), do: ""

  defp initial_last_name(last_name) when is_binary(last_name) do
    case String.at(last_name, 0) do
      nil -> nil
      initial -> "#{initial}."
    end
  end

  defp enum_value(nil), do: nil
  defp enum_value(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_value(value), do: value
end
