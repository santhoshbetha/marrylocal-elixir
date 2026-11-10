defmodule Marrylocal.Accounts.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  import Scrivener, only: [paginate: 2]
  alias Marrylocal.Repo
  alias Marrylocal.Accounts.Search

  alias Marrylocal.Accounts.{User, UserToken, UserNotifier}
  alias Marrylocal.DeletedUsers.DeletedUser

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  #def register_user(attrs) do
  #  %User{}
  #  |> User.email_changeset(attrs)
  #  |> Repo.insert()
  #end

  def register_user(attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.registration_changeset(%User{}, attrs))
    |> Ecto.Multi.run(:schedule_job, fn _repo, %{user: user} ->
        job = Marrylocal.Workers.DeletionReminder.new(
          %{user_id: user.id},
          schedule_in: 6 * 24 * 60 * 60
        )
        Oban.insert(job)
      end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user} # Return just the user so your controller doesn't break
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end
  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Marrylocal.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Marrylocal.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  #Function generates the token, saves it to the user_tokens table, and fires the email.
  def deliver_user_reset_password_instructions(user, reset_password_url_fun) do
    # Generate a 32-byte random token
    encoded_token = UserToken.build_email_token(user, "reset_password")

    # Send the email with the token injected into the URL
    UserEmail.reset_password_instructions(user, reset_password_url_fun.(encoded_token))
    |> Mailer.deliver()
  end

  # Same as `update_user_password/2` but does not require the current password to be valid.
  def reset_user_password(user, token, attrs) do
    Multi.new()
    |> Multi.update(:user, User.password_reset_changeset(user, attrs))
    |> Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["reset_password"]))
    |> Repo.transaction()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  def notify_nearby_users(new_user) do
    # 1. Find active users within 10km who have a push_token
    nearby_users =
      Search.list_users(new_user.latitude, new_user.longitude, %{"distance" => 10})
      |> Enum.filter(&(&1.push_token != nil))

    # 2. Send notifications in the background
    Task.start(fn ->
      Enum.each(nearby_users, fn user ->
        Marrylocal.Notifications.send_channel_notification(user.id, "Someone new is nearby!", "#{new_user.first_name} just joined.")
      end)
    end)
  end

  def broadcast_nearby_join(new_user) do
    # Find users within 30km (using your Search logic)
    nearby_users = Search.list_users(new_user.latitude, new_user.longitude, %{"distance" => 30})

    Enum.each(nearby_users, fn user ->
      MarrylocalWeb.Endpoint.broadcast("notifications:#{user.id}", "new_nearby_user", %{
        name: new_user.first_name,
        shortid: new_user.shortid
      })
    end)
  end

  def check_mutual_match(current_user, target_user) do
    # Check if target user has current user's shortid in their array
    # Uses the PostgreSQL "contains" operator (@>) via Ecto fragment
    query = from u in User,
      where: u.shortid == ^target_user.shortid and
             fragment("? @> ARRAY[?]", u.shortlist, ^current_user.shortid),
      select: count(u.id)

    case Repo.one(query) do
      1 -> {:ok, :mutual_match}
      0 -> {:ok, :single_interest}
    end
  end

  #Profile update:
  def update_user_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  def update_user_coordinates(user, attrs) do
    user
    |> User.location_changeset(attrs)
    |> Repo.update()
  end

  # Once the user pays, you should have a separate internal method to
  # clear the flag so they can finally update their location:
  def mark_location_payment_received(user) do
    user
    |> Ecto.Changeset.change(location_change_payment_required: false)
    |> Repo.update()
  end

  def get_user_by_id(user_id) do
    User
    |> Repo.get(user_id)
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_user_by_contact(identifier) do
    User
    |> where([u], u.email == ^identifier or u.phone_number == ^identifier)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_city_usercount(current_user) do
    # Determine opposite gender
    target_gender = if current_user.gender == "Male", do: "Female", else: "Male"

    User
    |> where([u], u.city == ^current_user.city)
    |> where([u], u.gender == ^target_gender)
    |> where([u], u.user_state == :active)
    |> Repo.aggregate(:count, :id)
  end

  def get_usercount_by_distance(current_user, radius_km) do
    # Determine opposite gender
    target_gender = if current_user.gender == "Male", do: "Female", else: "Male"

    # Convert km to meters for ST_DWithin (which uses meters for geography types)
    radius_m = radius_km * 1000

    User
    |> where([u], u.gender == ^target_gender)
    |> where([u], u.user_state == :active)
    # Fragment for PostGIS radius check
    |> where([u], fragment(
        "ST_DWithin(ST_SetSRID(ST_MakePoint(u.longitude, u.latitude), 4326)::geography,
                    ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
        ^current_user.longitude, ^current_user.latitude, ^radius_m
      ))
    |> Repo.aggregate(:count, :id)
  end

  def get_usercount_by_date(date \\ Date.utc_today()) do
    from(u in User,
      # Cast the timestamp to a date in Postgres for an accurate match
      where: fragment("?::date", u.date_of_creation) == ^date
    )
    |> Repo.aggregate(:count, :id)
  end

  #function now enforces a max limit of 8 and ignores further referrals once reached.
  def append_to_referee_emails(referral_code, new_email) do
    Repo.transaction(fn ->
      referrer = Repo.get_by!(User, referral_code: referral_code)

      # 1. ENFORCE LIMIT: Max 8 referrals
      current_count = Enum.count(referrer.referee_emails || [])
      if current_count >= 8 do
        Repo.rollback(:referral_limit_reached)
      end

      # 2. VALIDATION: Prevent self-referral
      if String.downcase(referrer.email) == String.downcase(new_email) do
        Repo.rollback(:self_referral_not_allowed)
      end

      # 3. Update list (Unique emails only)
      new_list = [new_email | (referrer.referee_emails || [])] |> Enum.uniq()

      referrer
      |> Ecto.Changeset.change(referee_emails: new_list)
      |> Repo.update!()
    end)
  end

  # Uses Repo.update_all with the push operator to append the
  # shortid directly into the array in the database.
  def add_to_shortlistX(current_user, target_shortid) do
    # 1. Verify the target exists first
    case Repo.get_by(User, shortid: target_shortid) do
      nil ->
        {:error, :not_found}

      _target ->
        # 2. Atomic update to append to the array
        # 'push' is a special Ecto key for PostgreSQL array columns
        from(u in User, where: u.id == ^current_user.id)
        |> Repo.update_all(push: [shortlist: target_shortid])

        {:ok, target_shortid}
    end
  end

  def add_to_shortlist(current_user, target_shortid) do
    case Repo.get_by(User, shortid: target_shortid) do
      nil -> {:error, :not_found}

      _target ->
        # Only update if the shortid is NOT already in the array
        from(u in User,
          where: u.id == ^current_user.id and
                fragment("NOT (? @> ARRAY[?])", u.shortlist, ^target_shortid)
        )
        |> Repo.update_all(push: [shortlist: target_shortid])

        {:ok, target_shortid}
    end
  end

  #function targets the shortlist array and removes all instances of the specific target_shortid.
  def remove_from_shortlist(current_user, target_shortid) do
    # The entire query (where + update) should be inside the from()
    query = from u in User,
      where: u.id == ^current_user.id,
      update: [set: [shortlist: fragment("array_remove(shortlist, ?)", ^target_shortid)]]

    Repo.update_all(query, [])

    {:ok, target_shortid}
  end

  def list_shortlisted_users1(shortid_list, params \\ %{}) do
    query = User
      |> where([u], u.shortid in ^shortid_list)
      |> where([u], u.user_state == :active) # Only show active users

    Repo.paginate(query, page: params["page"] || 1)
  end

  # Mutual Interest indicators on your shortlist
  # We use a PostgreSQL Fragment with the @> (contains) operator.
  # This allows the database to calculate the mutual status in a single pass.
  def list_shortlisted_users(current_user, params \\ %{}) do
    shortid_list = current_user.shortlist || []

    query = User
      |> where([u], u.shortid in ^shortid_list)
      |> where([u], u.user_state == :active)
      # Select a virtual field 'is_mutual' by checking if
      # current_user.shortid is inside the target user's shortlist array
      |> select_merge([u], %{
        is_mutual: fragment("? @> ARRAY[?]", u.shortlist, ^current_user.shortid)
      })

    Repo.paginate(query, page: params["page"] || 1)
  end

  def get_daily_reset_stats do
    one_year_ago = DateTime.utc_now() |> DateTime.add(-365, :day)

    from(u in User,
      where: fragment("?::date", u.date_of_activation) == fragment("?::date", ^one_year_ago)
    )
    |> Repo.aggregate(:count, :id)
  end

  def delete_user_account(user) do
    Ecto.Multi.new()
    # 1. Update the user state to 'deleted'
    |> Ecto.Multi.update(:user_update, User.changeset(user, %{user_state: :deleted}))

    # 2. Archive the data to the 'deleted_users' table (your soft-delete logic)
    |> Ecto.Multi.insert(:archive, %DeletedUser{
      original_user_id: user.id,
      email: user.email,
      aadhar_number: user.aadhar_number,
      data: Map.from_struct(user) |> Map.delete(:__meta__),
      reason: "user_requested"
    })

    # 3. Schedule the Oban worker to wipe the R2 folder
    |> Ecto.Multi.insert(:cleanup_job, fn _ ->
      Marrylocal.Workers.R2Cleanup.new(%{shortid: user.shortid})
    end)

    # 4. Clear the images array in the DB (since files will be gone from R2)
    |> Ecto.Multi.update(:clear_images, User.changeset(user, %{images: []}))

    |> Repo.transaction()
  end

  def deactivate_user_account(user) do
    user
    |> User.changeset(%{user_state: :inactive})
    |> Repo.update()
  end

  def deactivate_user(user) do
    user
    |> Ecto.Changeset.change(user_state: :inactive)
    |> Repo.update()
  end

  #Database Level Throttling (Extra Safety)
  # extremely aggressive about cost-saving, you can check the database to see when the last
  # reset_password token was created. If it was less than 15 minutes ago, don't even call the Mailer.
  def deliver_user_reset_password_instructions2(user, url_fun) do
    import Ecto.Query

    # Check if a token was sent in the last 15 minutes
    fifteen_mins_ago = DateTime.utc_now() |> DateTime.add(-15, :minute)

    recent_token_exists = Repo.exists?(
      from t in UserToken,
      where: t.user_id == ^user.id and t.context == "reset_password" and t.inserted_at > ^fifteen_mins_ago
    )

    if recent_token_exists do
      {:error, :already_sent_recently}
    else
      # ... generate token and send email logic ...
    end
  end

  def register_admin(attrs) do
    %User{}
    |> User.admin_registration_changeset(attrs)
    |> Repo.insert()
  end


  #Images:
  def generate_presigned_url(filename) do
    # Generate a unique path: "uploads/users/shortid/filename.jpg"
    s3_path = "uploads/#{filename}"

    # Generate a PUT URL valid for 1 hour
    {:ok, url} = ExAws.S3.presigned_url(
      ExAws.Config.new(:s3),
      :put,
      "your-bucket-name",
      s3_path,
      expires_in: 3600
    )

    {:ok, %{upload_url: url, public_url: "https://your-bucket.s3.amazonaws.com/#{s3_path}"}}
  end
end
