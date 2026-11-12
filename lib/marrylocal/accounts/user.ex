defmodule Marrylocal.Accounts.User do
  use Ecto.Schema
  use Waffle.Ecto.Schema
  import Ecto.Changeset

  alias Marrylocal.Accounts.SignupGuard

  @admin_update_fields [
    :email_verified,
    :aadhar_verified,
    :passport_verified,
    :license_verified,
    :terms_accepted,
    :onetime_fees_paid,
    :onetime_fees_required,
    :last_payment_at,
    :accepted_one_time_fees_amount,
    :max_search_distance,
    :age,
    :is_beta_tester,
    :user_state,
    :latitude,
    :longitude,
    :state,
    :city,
    :force_verification_required,
    :community_search_active,
    :sample_profile
  ]

  # The admin UI and older mobile builds use the long-form spellings. Accept
  # both, but always persist the schema's canonical column names.
  @admin_attr_aliases %{
    "aadhaar_verified" => "aadhar_verified",
    "one_time_fees_paid" => "onetime_fees_paid",
    "one_time_fees_required" => "onetime_fees_required",
    "last_fee_paid_at" => "last_payment_at"
  }

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    field :first_name, :string
    field :last_name, :string
    field :user_handle, :string
    # Virtual only: the raw birthday is parsed in memory and never persisted.
    field :birth_date, :date, virtual: true
    # Legacy column kept mapped for migration compatibility; new writes are nil.
    field :date_of_birth, :date
    field :age, :integer
    field :gender, :string
    field :state, :string
    field :city, :string
    field :language, :string
    field :religion, :string
    field :community, :string
    field :caste, :string
    field :phone_number, :string
    field :latitude, :float
    field :longitude, :float

    # Native PostGIS geography(Point, 4326). Kept alongside the legacy float
    # columns while clients migrate; only this column is used for querying.
    field :location, Geo.PostGIS.Geometry

    # Waffle.Ecto stores the object key; `Avatar.url/1` expands it to the
    # configured Cloudflare R2 public asset host.
    field :avatar, Marrylocal.Uploaders.Avatar.Type
    field :bio, :string
    field :facebook, :string
    field :instagram, :string
    field :whatsapp, :string
    field :shortid, :string
    field :aadhar_number, :string
    field :around_user_count, :integer, default: 0
    field :verify_retry_count, :integer, default: 0
    field :password_retry_count, :integer, default: 0

    # Enums
    field :education_level, Ecto.Enum,
      values: [:"High School", :"Plus 2 level", :"Bachelors level", :"Masters level"]

    field :economic_status, Ecto.Enum,
      values: [:"Below Middleclass", :Middleclass, :"Above Middleclass"]

    field :user_state, Ecto.Enum, values: [:active, :inactive, :deleted], default: :inactive
    field :role, Ecto.Enum, values: [:admin, :user], default: :user

    # Booleans
    field :job_status, :boolean
    field :show_phone, :boolean, default: false
    field :show_facebook, :boolean, default: false
    field :show_instagram, :boolean, default: false
    field :show_community, :boolean, default: false
    field :show_in_other_religion_people_search, :boolean, default: false
    field :hide_last_name, :boolean, default: true
    field :restrict_lookup_to_200km, :boolean, default: true
    field :allow_email_search, :boolean, default: false
    field :allow_phone_search, :boolean, default: false
    field :allow_handle_search, :boolean, default: true
    field :is_beta_tester, :boolean, default: false
    field :community_search_active, :boolean, default: false
    field :multi_location_slots, :map, default: %{}
    field :location_2_state, :string
    field :location_2_city, :string
    field :location_2_geom, Geo.PostGIS.Geometry
    field :location_2_last_changed_at, :utc_datetime
    field :location_2_purchased_at, :utc_datetime
    field :location_2_expires_at, :utc_datetime
    field :location_3_state, :string
    field :location_3_city, :string
    field :location_3_geom, Geo.PostGIS.Geometry
    field :location_3_last_changed_at, :utc_datetime
    field :location_3_purchased_at, :utc_datetime
    field :location_3_expires_at, :utc_datetime
    field :email_verified, :boolean, default: false
    field :aadhar_verified, :boolean, default: false
    field :passport_verified, :boolean, default: false
    field :license_verified, :boolean, default: false
    field :terms_accepted, :boolean, default: false
    field :core_details_edited, :boolean, default: false
    field :onetime_fees_paid, :boolean, default: false
    field :onetime_fees_required, :boolean, default: false
    field :force_verification_required, :boolean, default: false
    field :date_of_last_payment, :date
    field :last_payment_at, :utc_datetime
    field :sample_profile, :boolean, default: false
    field :default_coordinates_set, :boolean, default: true
    field :user_coordinates_set, :boolean, default: false
    field :location_change_payment_required, :boolean, default: false

    # Integers with defaults
    field :accepted_one_time_fees_amount, :integer, default: 500
    field :accepted_years_initial_term, :integer, default: 1
    # stored as integer (kms)
    field :max_search_distance, :integer, default: 100

    # Identifiers (Short-unique-id logic usually handled in changeset)
    field :referral_code, :string
    field :referred_by_id, :id
    field :referral_credits_count, :integer, default: 0
    field :referrer, :string

    # Arrays and JSONB
    field :shortlist, {:array, :string}, default: []
    field :images, {:array, :string}, default: []
    field :referree_emails, {:array, :string}, default: []
    # jsonb in DB
    field :addons, :map, default: nil

    # Timestamps/Dates
    field :time_of_login, :utc_datetime
    field :last_login_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :last_active_at, :utc_datetime
    field :date_of_creation, :utc_datetime
    field :date_of_activation, :utc_datetime
    field :date_of_location, :utc_datetime
    field :date_of_coordinates, :utc_datetime

    field :push_token, :string
    field :is_mutual, :boolean, virtual: true, default: false

    field :invite_code, :string, virtual: true

    has_one :subscription, Marrylocal.Accounts.Subscription

    has_many :notifications, Marrylocal.Notifications.Notification

    has_many :outgoing_relationships, Marrylocal.Relationships.Relationship,
      foreign_key: :actor_id

    has_many :incoming_relationships, Marrylocal.Relationships.Relationship,
      foreign_key: :target_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    attrs = normalize_birth_date_attrs(attrs)

    user
    # Add all fields here TODO
    |> cast(attrs, [:birth_date, :first_name, :email])
    |> validate_required([:first_name, :email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    # Validate Aadhar Format (12 digits, no start with 0 or 1)
    # |> validate_format(:aadhar_number, ~r/^[2-9]{1}[0-9]{11}$/, message: "must be a valid 12-digit Aadhar number")
    # Custom function for the 10-char ID
    |> generate_referral_code()
    # Custom function for the shortid
    |> put_shortid()
    |> unique_constraint(:phone_number)
    |> unique_constraint(:email)
    |> unique_constraint(:referral_code)
    |> validate_birth_date()

    # |> unique_constraint(:aadhar_number)
  end

  @doc """
  Administrative changeset for verification, fee, location, and account-state
  fields.

  Deliberately excludes `role`, `email`, password, and token fields so a bulk or
  single-user admin payload can never escalate privileges.
  """
  def admin_changeset(user, attrs) when is_map(attrs) do
    attrs = normalize_admin_attrs(attrs)

    user
    |> cast(attrs, @admin_update_fields)
    |> validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
    |> validate_number(:max_search_distance, greater_than: 0, less_than_or_equal_to: 1000)
    |> validate_number(:accepted_one_time_fees_amount, greater_than_or_equal_to: 0)
  end

  defp normalize_admin_attrs(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Enum.reduce(@admin_attr_aliases, attrs, fn {alias_key, canonical}, acc ->
      case Map.fetch(acc, alias_key) do
        {:ok, value} ->
          acc
          |> Map.put_new(canonical, value)
          |> Map.delete(alias_key)

        :error ->
          acc
      end
    end)
  end

  defp validate_birth_date(changeset) do
    case get_field(changeset, :birth_date) do
      %Date{} = dob ->
        age = calculate_age(dob)

        cond do
          age < 18 ->
            add_error(changeset, :date_of_birth, "must be at least 18 years old")

          age > 120 ->
            add_error(changeset, :date_of_birth, "is not a valid date of birth")

          true ->
            put_calculated_age(changeset)
        end

      _ ->
        add_error(changeset, :date_of_birth, "can't be blank")
    end
  end

  defp put_calculated_age(changeset) do
    case get_field(changeset, :birth_date) do
      %Date{} = dob ->
        changeset
        |> put_change(:age, calculate_age(dob))
        |> put_change(:date_of_birth, nil)

      _ ->
        changeset
    end
  end

  defp normalize_birth_date_attrs(attrs) when is_map(attrs) do
    normalized = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    birth_date = normalized["birth_date"] || normalized["date_of_birth"]

    normalized
    |> Map.drop(["date_of_birth"])
    |> Map.put("birth_date", birth_date)
  end

  defp normalize_birth_date_attrs(attrs), do: attrs

  defp normalize_registration_attrs(attrs) when is_map(attrs) do
    attrs = normalize_birth_date_attrs(attrs)

    case attrs["phone_number"] do
      nil -> attrs
      phone -> Map.put(attrs, "phone_number", SignupGuard.normalize_phone(phone))
    end
  end

  defp normalize_registration_attrs(attrs), do: attrs

  defp validate_non_disposable_email(changeset) do
    email = get_field(changeset, :email)

    if SignupGuard.disposable_email?(email) do
      add_error(changeset, :email, "temporary email domains are not allowed")
    else
      changeset
    end
  end

  defp calculate_age(dob) do
    today = Date.utc_today()
    age = today.year - dob.year

    # Adjust if the birthday hasn't happened yet this year
    if Date.compare(today, %{dob | year: today.year}) == :lt do
      age - 1
    else
      age
    end
  end

  # Verhoeff algorithm for aadhar later

  defp generate_referral_code(changeset) do
    if get_field(changeset, :referral_code) == nil do
      # Exactly eight characters: the ML product prefix + six Base32 symbols.
      random =
        :crypto.strong_rand_bytes(5)
        |> Base.encode32(padding: false, case: :upper)
        |> binary_part(0, 6)

      put_change(changeset, :referral_code, "ML" <> random)
    else
      changeset
    end
  end

  defp put_shortid(changeset) do
    case get_field(changeset, :shortid) do
      nil -> put_change(changeset, :shortid, generate_shortid(9))
      _ -> changeset
    end
  end

  defp generate_shortid(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end

  def add_image_changeset(user, attrs) do
    user
    |> cast(attrs, [:images])
    |> validate_length(:images, max: 10, message: "can contain at most 10 photos")
    |> check_constraint(:images,
      name: :images_limit,
      message: "You can only have up to 10 photos"
    )
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  def registration_changeset(user, attrs, opts \\ []) do
    attrs = normalize_registration_attrs(attrs)

    user
    |> cast(attrs, [
      :email,
      :phone_number,
      :birth_date,
      :first_name,
      :last_name,
      :user_handle,
      :city,
      :state,
      :gender,
      :language,
      :religion,
      :community,
      :caste,
      :education_level,
      :economic_status,
      :job_status,
      :password,
      :password_confirmation
    ])
    |> validate_required([:email, :phone_number, :first_name, :password])
    |> validate_email([])
    |> validate_non_disposable_email()
    |> unique_constraint(:phone_number)
    |> validate_format(:phone_number, ~r/^\d{10}$/,
      message: "must be a valid 10-digit Indian mobile number"
    )
    |> validate_password(opts)
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_handle()
    |> put_change(:user_state, :active)
    |> generate_referral_code()
    |> unique_constraint(:referral_code)
    |> validate_birth_date()
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Marrylocal.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  def admin_registration_changeset(user, attrs) do
    attrs = normalize_registration_attrs(attrs)

    user
    |> cast(attrs, [
      :email,
      :phone_number,
      :birth_date,
      :first_name,
      :last_name,
      :city,
      :state,
      :gender,
      :password,
      :password_confirmation,
      :invite_code
    ])
    |> validate_required([
      :first_name,
      :last_name,
      :email,
      :phone_number,
      :birth_date,
      :gender,
      :password,
      :invite_code
    ])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_non_disposable_email()
    |> validate_format(:phone_number, ~r/^\d{10}$/, message: "must be exactly 10 digits")
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_invite_code()
    # Force the role to admin
    |> put_change(:role, :admin)
    # Admins are active by default
    |> put_change(:user_state, :active)
    # Calculates the persisted integer age and clears the virtual raw date.
    |> validate_birth_date()
    |> generate_referral_code()
    |> unique_constraint(:email)
    |> unique_constraint(:phone_number)
    |> unique_constraint(:referral_code)
    |> validate_password(min_length: 8)
  end

  @doc """
  Validates the administrative invite code against `ADMIN_INVITE_CODE`.

  `Plug.Crypto.secure_compare/2` avoids leaking the expected value through
  timing. An unset or empty environment variable rejects every code.
  """
  def admin_invite_code_valid?(code) when is_binary(code) do
    expected = System.get_env("ADMIN_INVITE_CODE")

    is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(code, expected)
  end

  def admin_invite_code_valid?(_code), do: false

  defp validate_invite_code(changeset) do
    code = get_field(changeset, :invite_code)

    if admin_invite_code_valid?(code) do
      changeset
    else
      add_error(
        changeset,
        :invite_code,
        "is invalid. You are not authorized to create an admin account."
      )
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: Keyword.get(opts, :min_length, 12), max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now, email_verified: true)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Pbkdf2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Marrylocal.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :first_name,
      :last_name,
      :user_handle,
      :bio,
      :gender,
      :education_level,
      :economic_status,
      :job_status,
      :state,
      :city,
      :language,
      :religion,
      :community,
      :caste,
      :facebook,
      :instagram,
      :whatsapp,
      :show_phone,
      :show_facebook,
      :show_instagram,
      :show_community,
      :show_in_other_religion_people_search,
      :hide_last_name,
      :restrict_lookup_to_200km,
      :allow_email_search,
      :allow_phone_search,
      :allow_handle_search,
      :terms_accepted,
      :max_search_distance
    ])
    |> validate_length(:bio, max: 500)
    |> validate_handle()
    # Raw birth dates must never survive a profile write.
    |> put_change(:date_of_birth, nil)
  end

  @doc """
  Claims a public handle. Handles are 5-15 characters, start with a letter, and
  contain only letters, numbers, or underscores. Uniqueness is case-insensitive
  and enforced by the partial functional index created in the migration.
  """
  def handle_changeset(user, handle) when is_binary(handle) do
    user
    |> change(user_handle: String.trim(handle))
    |> validate_required(:user_handle)
    |> validate_handle()
  end

  defp validate_handle(changeset) do
    case get_change(changeset, :user_handle) do
      nil ->
        changeset

      _handle ->
        changeset
        |> validate_length(:user_handle, min: 5, max: 15)
        |> validate_format(
          :user_handle,
          ~r/^[A-Za-z][A-Za-z0-9_]{4,14}$/,
          message:
            "must be 5-15 characters, start with a letter, and contain only letters, numbers, or underscores"
        )
        |> unique_constraint(:user_handle,
          name: :users_user_handle_lower_index,
          message: "has already been taken"
        )
    end
  end

  @doc """
  Casts a multipart avatar upload into the Waffle.Ecto field.

  `cast_attachments/3` wraps the upload with the user struct as the Waffle scope,
  which `Marrylocal.Uploaders.Avatar.storage_dir/2` needs for the per-user R2
  prefix. A plain `cast/3` passes a nil scope and raises inside `user.id`.
  The uploader validates extension and content type before storage; this
  changeset only accepts files, never client-supplied path strings.
  """
  def avatar_changeset(user, attrs) do
    user
    |> cast_attachments(attrs, [:avatar])
    |> validate_required([:avatar])
  end

  def location_changeset(user, attrs) do
    coordinate_attrs = fuzzed_coordinate_attrs(attrs)

    user
    |> cast(coordinate_attrs, [:latitude, :longitude])
    |> validate_required([:latitude, :longitude])
    # Custom check for payment requirement
    |> validate_payment_not_required()
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> put_postgis_location()
    |> put_change(:date_of_coordinates, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:date_of_location, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:user_coordinates_set, true)
    |> put_change(:default_coordinates_set, false)
  end

  @doc "Returns true when a purchased location addon has not expired."
  def location_active?(%__MODULE__{} = user, slot) do
    case location_expiry(user, slot) do
      %DateTime{} = expires_at ->
        DateTime.compare(expires_at, DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end

  def location_expiry(user, "location_2"), do: user.location_2_expires_at
  def location_expiry(user, :location_2), do: user.location_2_expires_at
  def location_expiry(user, "location_3"), do: user.location_3_expires_at
  def location_expiry(user, :location_3), do: user.location_3_expires_at
  def location_expiry(_user, _slot), do: nil

  def location_last_changed_at(user, "location_2"), do: user.location_2_last_changed_at
  def location_last_changed_at(user, :location_2), do: user.location_2_last_changed_at
  def location_last_changed_at(user, "location_3"), do: user.location_3_last_changed_at
  def location_last_changed_at(user, :location_3), do: user.location_3_last_changed_at
  def location_last_changed_at(_user, _slot), do: nil

  # Fuzz before Ecto validates or writes the PostGIS point. The raw client
  # latitude/longitude never reaches PostgreSQL.
  defp fuzzed_coordinate_attrs(attrs) do
    latitude = parse_coordinate(attrs["latitude"] || attrs[:latitude])
    longitude = parse_coordinate(attrs["longitude"] || attrs[:longitude])

    if is_number(latitude) and is_number(longitude) do
      {fuzzed_lat, fuzzed_lng} = Marrylocal.Geo.fuzz_coordinates(latitude, longitude)
      %{latitude: fuzzed_lat, longitude: fuzzed_lng}
    else
      %{latitude: latitude, longitude: longitude}
    end
  end

  defp parse_coordinate(value) when is_number(value), do: value * 1.0

  defp parse_coordinate(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_coordinate(_value), do: nil

  # The geography value is always derived on the server. Clients can only send
  # latitude/longitude, so they can never inject an arbitrary WKB payload.
  defp put_postgis_location(changeset) do
    with latitude when is_number(latitude) <- get_field(changeset, :latitude),
         longitude when is_number(longitude) <- get_field(changeset, :longitude) do
      put_change(
        changeset,
        :location,
        %Geo.Point{coordinates: {longitude * 1.0, latitude * 1.0}, srid: 4326}
      )
    else
      _ -> changeset
    end
  end

  defp validate_payment_not_required(changeset) do
    # get_field/2 gets the current value from the struct or the changes
    if get_field(changeset, :location_change_payment_required) do
      add_error(changeset, :latitude, "Payment is required to change your location")
    else
      changeset
    end
  end
end
