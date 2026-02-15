defmodule Marrylocal.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @admin_invite_codes ["ADMIN4355", "SUPERUSER4355", "MARRYLOCALADMIN4355"]

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    field :first_name, :string
    field :last_name, :string
    field :date_of_birth, :date
    field :age, :integer
    field :gender, :string
    field :state, :string
    field :city, :string
    field :language, :string
    field :religion, :string
    field :community, :string
    field :phone_number, :string
    field :latitude, :float
    field :longitude, :float
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
    field :education_level, Ecto.Enum, values: [:"High School", :"Plus 2 level", :"Bachelors level", :"Masters level"]
    field :economic_status, Ecto.Enum, values: [:"Below Middleclass", :Middleclass, :"Above Middleclass"]
    field :user_state, Ecto.Enum, values: [:active, :inactive, :deleted], default: :inactive
    field :role, Ecto.Enum, values: [:admin, :user], default: :user

    # Booleans
    field :job_status, :boolean
    field :show_phone, :boolean, default: false
    field :show_facebook, :boolean, default: false
    field :show_instagram, :boolean, default: false
    field :show_community, :boolean, default: false
    field :show_in_other_religion_people_search, :boolean, default: false
    field :email_verified, :boolean, default: false
    field :aadhar_verified, :boolean, default: false
    field :passport_verified, :boolean, default: false
    field :license_verified, :boolean, default: false
    field :terms_accepted, :boolean, default: false
    field :onetime_fees_paid, :boolean, default: false
    field :onetime_fees_required, :boolean, default: false
    field :sample_profile, :boolean, default: false
    field :default_coordinates_set, :boolean, default: true
    field :user_coordinates_set, :boolean, default: false
    field :location_change_payment_required, :boolean, default: false

    # Integers with defaults
    field :accepted_one_time_fees_amount, :integer, default: 500
    field :accepted_years_initial_term, :integer, default: 1
    field :max_search_distance, :integer, default: 100 # stored as integer (kms)

    # Identifiers (Short-unique-id logic usually handled in changeset)
    field :referral_code, :string
    field :referrer, :string

    # Arrays and JSONB
    field :shortlist, {:array, :integer}, default: []
    field :images, {:array, :string}, default: []
    field :referree_emails, {:array, :string}, default: []
    field :addons, :map, default: nil # jsonb in DB

    # Timestamps/Dates
    field :time_of_login, :utc_datetime
    field :date_of_creation, :utc_datetime
    field :date_of_activation, :utc_datetime
    field :date_of_location, :utc_datetime
    field :date_of_coordinates, :utc_datetime

    field :push_token, :string
    field :is_mutual, :boolean, virtual: true, default: false

    field :invite_code, :string, virtual: true

    has_one :subscription, Marrylocal.Accounts.Subscription

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:date_of_birth, :first_name, :email]) # Add all fields here TODO
    |> validate_required([:first_name, :email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email address")
    # Validate Aadhar Format (12 digits, no start with 0 or 1)
    #|> validate_format(:aadhar_number, ~r/^[2-9]{1}[0-9]{11}$/, message: "must be a valid 12-digit Aadhar number")
    |> generate_referral_code() # Custom function for the 10-char ID
    |> put_shortid() # Custom function for the shortid
    |> unique_constraint(:phone_number)
    |> unique_constraint(:email)
    |> validate_required([:date_of_birth])
    |> put_calculated_age()
    #|> unique_constraint(:aadhar_number)
  end

  defp put_calculated_age(changeset) do
    case get_field(changeset, :date_of_birth) do
      %Date{} = dob ->
        age = calculate_age(dob)
        put_change(changeset, :age, age)
      _ ->
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
  #Verhoeff algorithm for aadhar later

  defp generate_referral_code(changeset) do
    if get_field(changeset, :referral_code) == nil do
      put_change(changeset, :referral_code, MnemonicSlugs.generate_slug(10)) # Or your ID generator
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
    |> check_constraint(:images, name: :images_limit, message: "You can only have up to 10 photos")
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

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :phone_number, :date_of_birth, :first_name, :last_name, :city, :state, :gender, :password])
    |> validate_required([:email, :phone_number, :date_of_birth, :first_name, :password])
    |> validate_email([])
    |> validate_password([])
    |> put_calculated_age()
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
    user
    |> cast(attrs, [:email, :phone_number, :date_of_birth, :city, :state, :gender, :password, :invite_code])
    |> validate_required([:email, :phone_number, :password, :invite_code])
    |> validate_invite_code()
    |> put_change(:role, :admin)      # Force the role to admin
    |> put_change(:user_state, :active) # Admins are active by default
    |> put_calculated_age()            # Reuse your age logic
    |> validate_password([])           # Your existing password hashing
  end

  defp validate_invite_code(changeset) do
    code = get_field(changeset, :invite_code)
    if code in @admin_invite_codes do
      changeset
    else
      add_error(changeset, :invite_code, "is invalid. You are not authorized to create an admin account.")
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
    |> validate_length(:password, min: 12, max: 72)
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
    change(user, confirmed_at: now)
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
      :first_name, :last_name, :bio, :gender, :education_level,
      :economic_status, :job_status, :state, :city, :language,
      :religion, :community, :facebook, :instagram, :whatsapp,
      :show_phone, :show_facebook, :show_instagram, :show_community,
      :max_search_distance
    ])
    |> validate_length(:bio, max: 500)
    # Age is automatically recalculated if date_of_birth is allowed here
    |> put_calculated_age()
  end

  def location_changeset(user, attrs) do
    user
    |> cast(attrs, [:latitude, :longitude])
    |> validate_required([:latitude, :longitude])
    # Custom check for payment requirement
    |> validate_payment_not_required()
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> put_change(:date_of_coordinates, DateTime.utc_now() |> DateTime.truncate(:second))
    |> put_change(:user_coordinates_set, true)
    |> put_change(:default_coordinates_set, false)
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
