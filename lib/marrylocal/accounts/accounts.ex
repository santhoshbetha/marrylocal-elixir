defmodule Marrylocal.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Marrylocal.Repo
  alias Marrylocal.Accounts.Search
  alias Marrylocal.Emails.UserEmail
  alias Marrylocal.Mailer

  alias Marrylocal.Accounts.{User, UserToken, UserNotifier, Subscription}
  alias Marrylocal.Accounts.UserPhotoHash
  alias Marrylocal.Billing
  alias Marrylocal.Features
  alias Marrylocal.Geo
  alias Marrylocal.DeletedUsers.DeletedUser

  require Logger

  @core_detail_fields [:first_name, :last_name, :language, :community]

  # Avoid re-sending a reset email for repeated requests. The token itself stays
  # valid for one hour, so a user who did receive the mail is not locked out.
  @reset_password_cooldown_minutes 15

  @doc """
  Returns the configured frontend origin used to build links inside emails.

  The value is read at runtime from `config :marrylocal, Marrylocal.Accounts,
  frontend_url: ...`, so no production host is compiled into a release.
  """
  def frontend_url do
    :marrylocal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:frontend_url, "http://localhost:5173")
    |> String.trim_trailing("/")
  end

  @doc "Builds the client confirmation link for an email-change token."
  def email_change_url(token) do
    query = URI.encode_query([{"type", "email_change"}, {"token", token}])
    "#{frontend_url()}/auth/confirm?#{query}"
  end

  @doc "Builds the frontend link that activates a newly registered account."
  def confirmation_url(token) do
    query = URI.encode_query([{"token", token}])
    "#{frontend_url()}/verify-email?#{query}"
  end

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

  @doc "Gets a live user by id, returning nil for missing/deleted accounts."
  def get_user(id) do
    case Repo.get(User, id) do
      nil -> nil
      %User{user_state: :deleted} -> nil
      user -> user
    end
  end

  @doc "Gets a user by short public identifier."
  def get_user_by_shortid(shortid) when is_binary(shortid) do
    Repo.get_by(User, shortid: shortid)
  end

  @doc "Gets a user by public handle. Case-insensitive."
  def get_user_by_handle(handle) when is_binary(handle) do
    trimmed = String.trim(handle)

    from(u in User,
      where: fragment("lower(?) = lower(?)", u.user_handle, ^trimmed)
    )
    |> Repo.one()
  end

  @doc """
  Case-insensitive handle availability check.

  `excluding_user_id` lets a user keep the handle they already own.
  """
  def handle_taken?(handle, excluding_user_id \\ nil)

  def handle_taken?(handle, excluding_user_id) when is_binary(handle) do
    trimmed = String.trim(handle)

    query =
      from(u in User,
        where:
          fragment("lower(?) = lower(?)", u.user_handle, ^trimmed) and
            not is_nil(u.user_handle)
      )

    query =
      if excluding_user_id do
        from(u in query, where: u.id != ^excluding_user_id)
      else
        query
      end

    Repo.exists?(query)
  end

  def handle_taken?(_handle, _excluding_user_id), do: false

  @doc "Returns every live user matching the given ids in one query."
  def list_users_by_ids([]), do: []

  def list_users_by_ids(ids) when is_list(ids) do
    User
    |> where([u], u.id in ^ids and u.user_state != :deleted)
    |> Repo.all()
  end

  ## Admin user queries

  @admin_user_limit 500

  @doc """
  Returns up to 500 users for the admin console, newest first.

  Supports a semicolon-separated `query` across names, email, phone, handle, and
  shortid, plus optional `state`/`city` filters. `"All"` and `"All Cities"` are
  treated as no filter.
  """
  def admin_search_users(params \\ %{}) when is_map(params) do
    params
    |> admin_search_query()
    |> Repo.all()
  end

  @doc "Builds the bounded admin search query without executing it."
  def admin_search_query(params) when is_map(params) do
    User
    |> admin_apply_search(params["query"])
    |> admin_apply_location(params["state"], params["city"])
    |> admin_apply_flags(params)
    |> order_by([u], desc: u.inserted_at, desc: u.id)
    |> limit(@admin_user_limit)
  end

  @doc """
  Finds one user by exact email, phone number, `@handle`, shortid, or id.

  Returns `nil` when nothing matches so the controller can answer with 404.
  """
  def admin_lookup_user(query) when is_binary(query) do
    value = query |> String.trim() |> String.trim_leading("@")

    if value == "" do
      nil
    else
      Repo.one(
        from u in User,
          where:
            u.email == ^value or u.phone_number == ^value or u.user_handle == ^value or
              u.shortid == ^value or fragment("?::text = ?", u.id, ^value),
          limit: 1
      )
    end
  end

  def admin_lookup_user(_query), do: nil

  @doc "Applies the administrative changeset to a single user."
  def admin_update_user(%User{} = user, attrs) when is_map(attrs) do
    user
    |> User.admin_changeset(attrs)
    |> Repo.update()
  end

  def admin_update_user(id, attrs) when is_map(attrs) do
    case normalize_admin_user_id(id) do
      nil ->
        {:error, :not_found}

      user_id ->
        with {:ok, user} <- get_user_by_id(user_id) do
          admin_update_user(user, attrs)
        end
    end
  end

  @doc """
  Atomically applies whitelisted admin fields to every requested user.

  Returns `{:ok, updated_count}`. Invalid values return `{:error, changeset}`;
  a payload with no recognised keys returns `{:error, :no_updates}`.
  """
  def admin_bulk_update_users(user_ids, updates) when is_list(user_ids) and is_map(updates) do
    ids =
      user_ids
      |> Enum.map(&normalize_admin_user_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    changeset = User.admin_changeset(%User{}, updates)

    cond do
      ids == [] ->
        {:ok, 0}

      not changeset.valid? ->
        {:error, changeset}

      changeset.changes == %{} ->
        {:error, :no_updates}

      true ->
        {count, _rows} =
          from(u in User, where: u.id in ^ids)
          |> Repo.update_all(set: Map.to_list(changeset.changes))

        {:ok, count}
    end
  end

  defp admin_apply_search(query, search) when is_binary(search) do
    terms =
      search
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    condition =
      Enum.reduce(terms, nil, fn term, acc ->
        term_condition = admin_search_term(term)

        if acc do
          dynamic([u], ^acc or ^term_condition)
        else
          term_condition
        end
      end)

    case condition do
      nil -> query
      condition -> where(query, ^condition)
    end
  end

  defp admin_apply_search(query, _search), do: query

  defp admin_search_term(term) do
    pattern = "%" <> escape_like(term) <> "%"

    dynamic(
      [u],
      ilike(u.first_name, ^pattern) or
        ilike(u.last_name, ^pattern) or
        ilike(u.email, ^pattern) or
        ilike(u.phone_number, ^pattern) or
        ilike(u.user_handle, ^pattern) or
        ilike(u.shortid, ^pattern)
    )
  end

  defp admin_apply_location(query, state, city) do
    query
    |> admin_filter_state(state)
    |> admin_filter_city(city)
  end

  defp admin_filter_state(query, state) when is_binary(state) and state not in ["", "All"] do
    where(query, [u], ilike(u.state, ^String.trim(state)))
  end

  defp admin_filter_state(query, _state), do: query

  defp admin_filter_city(query, city)
       when is_binary(city) and city not in ["", "All", "All Cities"] do
    where(query, [u], ilike(u.city, ^String.trim(city)))
  end

  defp admin_filter_city(query, _city), do: query

  # `unverified_only` means no identity document has ever been approved for the
  # account. Email confirmation is tracked separately and is returned to the
  # caller so it can decide whether that matters for a given triage task.
  defp admin_apply_flags(query, params) do
    query
    |> admin_filter_unverified(admin_flag(params, :unverified_only, "unverified_only"))
    |> admin_filter_paid(admin_flag(params, :paid_only, "paid_only"))
  end

  defp admin_filter_unverified(query, value) do
    if truthy_flag?(value) do
      where(
        query,
        [u],
        (is_nil(u.aadhar_verified) or u.aadhar_verified == false) and
          (is_nil(u.passport_verified) or u.passport_verified == false) and
          (is_nil(u.license_verified) or u.license_verified == false)
      )
    else
      query
    end
  end

  defp admin_filter_paid(query, value) do
    if truthy_flag?(value), do: where(query, [u], u.onetime_fees_paid == true), else: query
  end

  defp admin_flag(params, atom_key, string_key) do
    Map.get(params, string_key) || Map.get(params, atom_key)
  end

  defp truthy_flag?(value), do: value in [true, "true", "1", 1]

  defp normalize_admin_user_id(id) when is_integer(id), do: id

  defp normalize_admin_user_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_admin_user_id(_id), do: nil

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  ## User registration

  defp configured_annual_fee do
    case Application.get_env(:marrylocal, :billing, []) |> Keyword.get(:default_annual_fee_inr) do
      value when is_integer(value) and value > 0 -> value
      _ -> 500
    end
  end

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """

  # def register_user(attrs) do
  #  %User{}
  #  |> User.email_changeset(attrs)
  #  |> Repo.insert()
  # end

  def register_user(attrs) do
    with {:ok, referrer} <- resolve_referrer(attrs) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, fn _changes ->
        changeset = User.registration_changeset(%User{}, attrs)

        changeset =
          Ecto.Changeset.put_change(
            changeset,
            :accepted_one_time_fees_amount,
            configured_annual_fee()
          )

        if referrer do
          Ecto.Changeset.put_change(changeset, :referred_by_id, referrer.id)
        else
          changeset
        end
      end)
      |> Ecto.Multi.run(:referral_credit, fn repo, %{user: _user} ->
        credit_referrer(repo, referrer)
      end)
      |> Ecto.Multi.run(:schedule_job, fn _repo, %{user: user} ->
        schedule_deletion_reminder(user)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} ->
          case evaluate_gating(user) do
            {:ok, evaluated} -> {:ok, evaluated}
            _ -> {:ok, user}
          end

        {:error, :user, changeset, _} ->
          {:error, changeset}

        {:error, :referral_credit, reason, _} ->
          {:error, reason}

        {:error, :schedule_job, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns the authenticated user's referral code, earned credit value, and the
  people who joined with that code.
  """
  def referral_summary(user_id) do
    user = Repo.get!(User, user_id)

    referrals =
      from(u in User,
        where: u.referred_by_id == ^user_id,
        order_by: [desc: u.inserted_at],
        select: %{id: u.id, first_name: u.first_name, inserted_at: u.inserted_at}
      )
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :credit_value_inr, 50))

    credits_count = user.referral_credits_count || 0

    %{
      referral_code: user.referral_code,
      credits_count: credits_count,
      credit_value_inr: credits_count * 50,
      referrals: referrals
    }
  end

  defp resolve_referrer(attrs) do
    code = attrs["referred_by_code"] || attrs[:referred_by_code]

    if is_binary(code) and String.trim(code) != "" do
      case Repo.get_by(User, referral_code: String.upcase(String.trim(code))) do
        nil ->
          {:error, :invalid_referral_code}

        referrer ->
          email = attrs["email"] || attrs[:email]

          if is_binary(email) and String.downcase(referrer.email) == String.downcase(email) do
            {:error, :self_referral_not_allowed}
          else
            {:ok, referrer}
          end
      end
    else
      {:ok, nil}
    end
  end

  defp credit_referrer(_repo, nil), do: {:ok, nil}

  defp credit_referrer(repo, referrer) do
    {updated, _rows} =
      from(u in User, where: u.id == ^referrer.id)
      |> repo.update_all(inc: [referral_credits_count: 1])

    if updated == 1, do: {:ok, nil}, else: {:error, :referrer_not_found}
  end

  @doc """
  Activates paid addon features on the server after a verified payment event.

  The client never supplies dates or subscription status. A monthly interval is
  calculated from the server's UTC date and persisted on the subscription row.
  """
  def activate_subscription(user_id, items, start_date \\ Date.utc_today())
      when is_map(items) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        with :ok <- validate_addon_locations(user, items) do
          end_date = Date.add(start_date, 30)
          valid_until = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")
          purchased_at = DateTime.utc_now() |> DateTime.truncate(:second)
          community_active = items["community_search"] == true || user.community_search_active
          slots = merge_location_slots(user.multi_location_slots || %{}, items)
          addons = merge_legacy_addons(user.addons || %{}, items, community_active)
          location_attrs = location_entitlement_attrs(user, items, purchased_at)
          expires_2 = location_attrs[:location_2_expires_at]
          expires_3 = location_attrs[:location_3_expires_at]

          Repo.transaction(fn ->
            {:ok, updated_user} =
              user
              |> Ecto.Changeset.change(
                Map.merge(
                  %{
                    community_search_active: community_active,
                    multi_location_slots: slots,
                    addons: addons
                  },
                  location_attrs
                )
              )
              |> Repo.update()

            subscription =
              Repo.get_by(Subscription, user_id: user.id) ||
                %Subscription{user_id: user.id}

            {:ok, subscription} =
              subscription
              |> Subscription.changeset(%{
                status: "active",
                valid_until: valid_until,
                info: %{
                  "start_date" => Date.to_iso8601(start_date),
                  "end_date" => Date.to_iso8601(end_date),
                  "items" => items
                }
              })
              |> Repo.insert_or_update()

            maybe_insert_addon_invoice(
              user,
              "community_search",
              items["community_search"],
              purchased_at,
              valid_until
            )

            maybe_insert_addon_invoice(
              user,
              "location2",
              items["location2"],
              purchased_at,
              expires_2
            )

            maybe_insert_addon_invoice(
              user,
              "location3",
              items["location3"],
              purchased_at,
              expires_3
            )

            %{user: updated_user, subscription: subscription}
          end)
        end
    end
  end

  @doc "Rejects addon purchases that would duplicate an active location pair."
  def validate_addon_locations(%User{} = user, items) when is_map(items) do
    location_2 = items["location2"]
    location_3 = items["location3"]

    cond do
      duplicate_location?(user, :location_2, location_2) ->
        {:error, :duplicate_location}

      duplicate_location?(user, :location_3, location_3) ->
        {:error, :duplicate_location}

      duplicate_location_pair?(location_2, location_3) ->
        {:error, :duplicate_location}

      true ->
        :ok
    end
  end

  def validate_addon_locations(_user, _items), do: :ok

  @doc "True when a slot update would duplicate another active location pair."
  def duplicate_location?(%User{} = user, slot, %{"state" => state, "city" => city}) do
    duplicate_location?(user, slot, state, city)
  end

  def duplicate_location?(_user, _slot, _attrs), do: false

  def duplicate_location?(%User{} = user, slot, state, city) do
    target = normalize_location_pair(state, city)

    target != nil and
      Enum.any?(other_active_location_pairs(user, slot), fn {_slot, other_state, other_city} ->
        normalize_location_pair(other_state, other_city) == target
      end)
  end

  def duplicate_location?(_user, _slot, _state, _city), do: false

  defp duplicate_location_pair?(left, right) do
    normalize_location_pair(location_value(left, "state"), location_value(left, "city")) != nil and
      normalize_location_pair(location_value(left, "state"), location_value(left, "city")) ==
        normalize_location_pair(location_value(right, "state"), location_value(right, "city"))
  end

  defp location_value(%{} = location, key), do: location[key]
  defp location_value(_location, _key), do: nil

  defp other_active_location_pairs(user, exclude_slot) do
    []
    |> maybe_add_primary_pair(user, exclude_slot)
    |> maybe_add_secondary_pair(user, :location_2, exclude_slot)
    |> maybe_add_secondary_pair(user, :location_3, exclude_slot)
  end

  defp maybe_add_primary_pair(pairs, user, exclude_slot) do
    if exclude_slot != :primary and present_location_pair?(user.state, user.city) do
      [{:primary, user.state, user.city} | pairs]
    else
      pairs
    end
  end

  defp maybe_add_secondary_pair(pairs, user, slot, exclude_slot) do
    {state, city} = secondary_location_pair(user, slot)

    if slot != exclude_slot and User.location_active?(user, slot) and
         present_location_pair?(state, city) do
      [{slot, state, city} | pairs]
    else
      pairs
    end
  end

  defp secondary_location_pair(user, :location_2),
    do: {user.location_2_state, user.location_2_city}

  defp secondary_location_pair(user, :location_3),
    do: {user.location_3_state, user.location_3_city}

  defp present_location_pair?(state, city), do: is_binary(state) and is_binary(city)

  defp normalize_location_pair(state, city) do
    normalized_state = state |> to_string() |> String.trim() |> String.downcase()
    normalized_city = city |> to_string() |> String.trim() |> String.downcase()

    if normalized_state != "" and normalized_city != "" do
      {normalized_state, normalized_city}
    end
  end

  defp maybe_insert_addon_invoice(_user, _key, nil, _period_start, _period_end), do: :ok
  defp maybe_insert_addon_invoice(_user, _key, false, _period_start, _period_end), do: :ok

  defp maybe_insert_addon_invoice(user, key, _selected, period_start, period_end) do
    case Billing.create_itemized_invoice(user, key,
           period_start: period_start,
           period_end: period_end,
           payment_reference: "subscription-#{user.id}-#{System.system_time(:second)}"
         ) do
      {:ok, _invoice} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp location_entitlement_attrs(user, items, purchased_at) do
    attrs =
      %{}
      |> put_location_entitlement(user, :location_2, items["location2"], purchased_at)
      |> put_location_entitlement(user, :location_3, items["location3"], purchased_at)

    attrs
  end

  defp put_location_entitlement(attrs, user, slot, %{"city" => city, "state" => state}, now)
       when is_binary(city) and is_binary(state) and city != "" and state != "" do
    prefix = Atom.to_string(slot)
    current_expiry = Map.get(user, String.to_existing_atom("#{prefix}_expires_at"))
    base = latest_datetime(now, current_expiry)

    Map.merge(attrs, %{
      String.to_existing_atom("#{prefix}_city") => city,
      String.to_existing_atom("#{prefix}_state") => state,
      String.to_existing_atom("#{prefix}_purchased_at") => now,
      String.to_existing_atom("#{prefix}_expires_at") => DateTime.add(base, 30, :day)
    })
  end

  defp put_location_entitlement(attrs, _user, _slot, _value, _now), do: attrs

  defp latest_datetime(now, %DateTime{} = existing) do
    if DateTime.compare(existing, now) == :gt, do: existing, else: now
  end

  defp latest_datetime(now, _existing), do: now

  defp merge_location_slots(slots, items) do
    slots
    |> maybe_put_location("location2", items["location2"])
    |> maybe_put_location("location3", items["location3"])
  end

  defp maybe_put_location(slots, key, %{"city" => city, "state" => state})
       when is_binary(city) and is_binary(state) and city != "" do
    Map.put(slots, key, %{"city" => city, "state" => state})
  end

  defp maybe_put_location(slots, _key, _value), do: slots

  defp merge_legacy_addons(addons, items, community_active) do
    addons
    |> Map.delete("fullcitySearch")
    |> Map.put("communitySearch", community_active)
    |> put_legacy_location("location2", items["location2"], "city2", "state2")
    |> put_legacy_location("location3", items["location3"], "city3", "state3")
  end

  defp put_legacy_location(addons, key, %{"city" => city, "state" => state}, city_key, state_key)
       when is_binary(city) and is_binary(state) and city != "" do
    Map.put(addons, key, %{city_key => city, state_key => state})
  end

  defp put_legacy_location(addons, _key, _value, _city_key, _state_key), do: addons

  # Oban's manual test mode must not open a second checked-out connection
  # inside the SQL sandbox transaction, so the reminder is a no-op there.
  defp schedule_deletion_reminder(user) do
    if Keyword.get(Application.get_env(:marrylocal, Oban, []), :testing) == :manual do
      {:ok, :skipped}
    else
      job =
        Marrylocal.Workers.DeletionReminder.new(
          %{user_id: user.id},
          schedule_in: 6 * 24 * 60 * 60
        )

      Oban.insert(job)
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

  @doc """
  Generates a password-reset token, stores only its SHA-256 hash, and delivers
  the reset link to the user's email.

  Repeated requests within 15 minutes return `{:error, :already_sent_recently}`
  so callers can keep their response enumeration-safe without re-sending mail.
  """
  def deliver_user_reset_password_instructions(user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    if reset_password_email_sent_recently?(user) do
      {:error, :already_sent_recently}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
      Repo.insert!(user_token)

      user
      |> UserEmail.reset_password_instructions(reset_password_url_fun.(encoded_token))
      |> Mailer.deliver()
    end
  end

  defp reset_password_email_sent_recently?(user) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@reset_password_cooldown_minutes, :minute)

    Repo.exists?(
      from t in UserToken,
        where:
          t.user_id == ^user.id and t.context == "reset_password" and
            t.inserted_at > ^cutoff
    )
  end

  @doc """
  Same as `update_user_password/2` but does not require the current password.

  Only call this after `get_user_by_reset_password_token/1` has verified the
  emailed token. The password update and the revocation of every token owned by
  the user run in one transaction, so a failed update cannot leave live sessions
  behind.
  """
  def reset_user_password(%User{} = user, attrs) do
    Multi.new()
    |> Multi.update(:user, User.password_changeset(user, attrs))
    |> Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
    end
  end

  # Backwards-compatible arity kept for callers that still pass the raw token.
  @doc false
  def reset_user_password(%User{} = user, _token, attrs), do: reset_user_password(user, attrs)

  @doc "Gets the user by a valid password-reset token."
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  @doc """
  Confirms a user's email address from a single-use confirmation token.

  Confirmation consumes every token owned by the user, including any session
  created at registration. The caller can then issue a fresh bearer token.
  """
  def confirm_user_by_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query) do
      user
      |> User.confirm_changeset()
      |> update_user_and_delete_all_tokens()
      |> case do
        {:ok, {user, _expired_tokens}} -> {:ok, user}
        {:error, changeset} -> {:error, changeset}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def confirm_user_by_token(_token), do: {:error, :not_found}

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
  Marks a successful sign-in and refreshes presence-facing timestamps.
  """
  def record_login(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(
      time_of_login: now,
      last_login_at: now,
      last_seen_at: now
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, _changeset} -> user
    end
  end

  @doc """
  Refreshes a user's last-seen timestamp during token validation or a socket
  handshake. Writes are throttled to once per minute per user.
  """
  def touch_last_seen(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(now, -60, :second)

    Repo.update_all(
      from(u in User,
        where:
          u.id == ^user.id and
            (is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff)
      ),
      set: [last_seen_at: now, last_active_at: now]
    )

    :ok
  end

  @doc """
  Gets the user with the given opaque bearer token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil`.
  Only a SHA-256 hash of the token exists in Postgres.
  """
  def get_user_by_session_token(token) do
    case UserToken.verify_session_token_query(token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  @doc "Generates the short-lived Phoenix token used only for the WebSocket handshake."
  def generate_websocket_token(%User{} = user) do
    Phoenix.Token.sign(MarrylocalWeb.Endpoint, "user socket", user.id)
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
  Delivers the account confirmation instructions for a newly registered user.
  """
  def deliver_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)
    UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    case UserToken.hash_session_token(token) do
      {:ok, hashed_token} ->
        Repo.delete_all(from(UserToken, where: [token: ^hashed_token, context: "session"]))
        :ok

      :error ->
        :ok
    end
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
      Search.list_users(%{
        "latitude" => new_user.latitude,
        "longitude" => new_user.longitude,
        "distance" => 10
      }).entries
      |> Enum.filter(&(&1.push_token != nil))

    # 2. Send notifications in the background
    Task.start(fn ->
      Enum.each(nearby_users, fn user ->
        Marrylocal.Notifications.send_channel_notification(
          user.id,
          "Someone new is nearby!",
          "#{new_user.first_name} just joined."
        )
      end)
    end)
  end

  def broadcast_nearby_join(new_user) do
    # Find users within 30km (using your Search logic)
    nearby_users =
      Search.list_users(%{
        "latitude" => new_user.latitude,
        "longitude" => new_user.longitude,
        "distance" => 30
      }).entries

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
    query =
      from u in User,
        where:
          u.shortid == ^target_user.shortid and
            fragment("? @> ARRAY[?]", u.shortlist, ^current_user.shortid),
        select: count(u.id)

    case Repo.one(query) do
      1 -> {:ok, :mutual_match}
      0 -> {:ok, :single_interest}
    end
  end

  # Profile update:
  def update_user_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Stores a validated multipart avatar through Waffle into Cloudflare R2.

  Only `%Plug.Upload{}` values reach the changeset; client-supplied path strings
  are rejected by the Waffle.Ecto type.
  """
  def update_avatar(%User{} = user, attrs) do
    user
    |> User.avatar_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Stores the avatar and claims its fingerprint in one database transaction.

  Waffle's R2 upload runs while `User.avatar_changeset/2` is built, before the
  transaction starts. The user row and `user_photo_hashes` claim therefore commit
  or roll back together, which closes the duplicate-upload race.
  """
  def update_avatar_with_photo_hash(%User{} = user, attrs, photo_hash) do
    changeset = User.avatar_changeset(user, attrs)

    Repo.transaction(fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _hash} <- claim_photo_hash_in_transaction(updated, photo_hash, nil) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Clears the avatar reference. The R2 object is left for lifecycle cleanup."
  def clear_avatar(%User{} = user) do
    user
    |> Ecto.Changeset.change(avatar: nil)
    |> Repo.update()
  end

  @max_profile_photos 10

  @doc """
  Writes a gallery photo URL into the exact `images[slot_index]` position.

  Slots are zero-based and stable: uploading to slot 4 keeps slots 0-3 and the
  remaining slots untouched. Missing intermediate positions are padded with nil
  so the client can keep rendering a fixed ten-cell grid.
  """
  def update_user_image_at_slot(%User{} = user, image_url, slot_index)
      when is_integer(slot_index) and slot_index >= 0 and slot_index < @max_profile_photos and
             is_binary(image_url) do
    images =
      user.images
      |> List.wrap()
      |> pad_images_to_slot(slot_index)
      |> List.replace_at(slot_index, image_url)

    user
    |> User.add_image_changeset(%{images: images})
    |> Repo.update()
  end

  def update_user_image_at_slot(_user, _image_url, _slot_index),
    do: {:error, :invalid_slot_index}

  @doc """
  Writes one gallery slot and claims its photo fingerprint atomically.

  The R2 object is stored by `ProfilePhoto.store/1` before this function is
  called. This transaction only owns the user row and `user_photo_hashes`, so a
  duplicate fingerprint rolls both back and the controller can delete the
  just-uploaded object.
  """
  def update_user_image_at_slot_with_photo_hash(
        %User{} = user,
        image_url,
        slot_index,
        photo_hash
      )
      when is_integer(slot_index) and slot_index >= 0 and slot_index < @max_profile_photos and
             is_binary(image_url) do
    images =
      user.images
      |> List.wrap()
      |> pad_images_to_slot(slot_index)
      |> List.replace_at(slot_index, image_url)

    changeset = User.add_image_changeset(user, %{images: images})

    Repo.transaction(fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _hash} <-
             claim_photo_hash_in_transaction(updated, photo_hash, slot_index) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update_user_image_at_slot_with_photo_hash(
        _user,
        _image_url,
        _slot_index,
        _photo_hash
      ),
      do: {:error, :invalid_slot_index}

  @doc """
  Clears `images[slot_index]` without re-indexing the remaining photos.

  Indices stay stable so slot 4 does not become slot 3. Trailing nils are
  trimmed so the persisted array does not grow forever.
  """
  def clear_user_image_at_slot(%User{} = user, slot_index)
      when is_integer(slot_index) and slot_index >= 0 and slot_index < @max_profile_photos do
    images = List.wrap(user.images)

    images =
      if slot_index < length(images) do
        images
        |> List.replace_at(slot_index, nil)
        |> trim_trailing_nil_images()
      else
        images
      end

    user
    |> User.add_image_changeset(%{images: images})
    |> Repo.update()
  end

  def clear_user_image_at_slot(_user, _slot_index), do: {:error, :invalid_slot_index}

  @photo_hash_chunk_size 1_048_576

  @doc "SHA-256 fingerprint for an uploaded profile image, streamed in 1 MB chunks."
  def profile_photo_hash(path) when is_binary(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          hash_file(io, :crypto.hash_init(:sha256))
        after
          File.close(io)
        end

      {:error, _reason} ->
        nil
    end
  end

  def profile_photo_hash(_path), do: nil

  defp hash_file(io, state) do
    case IO.binread(io, @photo_hash_chunk_size) do
      :eof ->
        state
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:error, _reason} ->
        nil

      chunk ->
        hash_file(io, :crypto.hash_update(state, chunk))
    end
  end

  @doc "True when another user already has this exact photo active."
  def photo_hash_claimed?(photo_hash, user_id) do
    from(h in UserPhotoHash,
      where: h.photo_hash == ^photo_hash and h.active == true and h.user_id != ^user_id,
      select: count(h.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  @doc "Claims a photo fingerprint for one user and slot."
  def claim_photo_hash(%User{} = user, photo_hash, slot_index) do
    Repo.transaction(fn ->
      case claim_photo_hash_in_transaction(user, photo_hash, slot_index) do
        {:ok, hash} -> hash
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Shared by the public wrapper and the avatar/gallery update transactions.
  # Returns {:ok, hash} or {:error, reason}; callers inside Repo.transaction
  # must rollback themselves so the user row and claim commit together.
  defp claim_photo_hash_in_transaction(_user, nil, _slot_index), do: {:ok, nil}

  defp claim_photo_hash_in_transaction(%User{} = user, photo_hash, slot_index)
       when is_binary(photo_hash) do
    slot_index = normalize_photo_slot(slot_index)

    existing = Repo.get_by(UserPhotoHash, photo_hash: photo_hash, active: true)

    cond do
      existing && existing.user_id != user.id ->
        {:error, :duplicate_photo}

      existing && existing.user_id == user.id ->
        # The same member may reuse one exact image in another slot. The photo
        # is already protected against other users by the active hash row.
        {:ok, existing}

      true ->
        Repo.delete_all(
          from(h in UserPhotoHash,
            where: h.user_id == ^user.id and h.slot_index == ^slot_index
          )
        )

        case %UserPhotoHash{}
             |> UserPhotoHash.changeset(%{
               user_id: user.id,
               photo_hash: photo_hash,
               slot_index: slot_index,
               active: true
             })
             |> Repo.insert() do
          {:ok, hash} ->
            {:ok, hash}

          {:error, %Ecto.Changeset{} = changeset} ->
            if changeset.errors[:photo_hash] do
              {:error, :duplicate_photo}
            else
              {:error, changeset}
            end
        end
    end
  end

  @doc "Releases the fingerprint for a replaced or deleted photo slot."
  def release_photo_hash(%User{} = user, slot_index) do
    slot_index = normalize_photo_slot(slot_index)

    from(h in UserPhotoHash,
      where: h.user_id == ^user.id and h.slot_index == ^slot_index
    )
    |> Repo.delete_all()

    :ok
  end

  defp normalize_photo_slot(nil), do: -1
  defp normalize_photo_slot(value) when is_integer(value), do: value
  defp normalize_photo_slot(_value), do: -1

  defp pad_images_to_slot(images, slot_index) do
    missing = slot_index + 1 - length(images)
    if missing > 0, do: images ++ List.duplicate(nil, missing), else: images
  end

  defp trim_trailing_nil_images(images) do
    images
    |> Enum.reverse()
    |> Enum.drop_while(&is_nil/1)
    |> Enum.reverse()
  end

  @location_cooldown_days 30

  @doc "Returns the next server-authorized location change time."
  def location_change_allowed_at(%User{date_of_location: nil}), do: nil

  def location_change_allowed_at(%User{date_of_location: date_of_location}) do
    DateTime.add(date_of_location, @location_cooldown_days, :day)
  end

  @doc "True while the server-side monthly location cooldown is active."
  def location_change_locked?(%User{} = user) do
    case location_change_allowed_at(user) do
      nil -> false
      allowed_at -> DateTime.compare(allowed_at, DateTime.utc_now()) == :gt
    end
  end

  @doc """
  Server-side density evaluator. Calculates opposite-gender city and 50km
  metrics and persists the resulting annual-fee / verification gates.
  """
  def evaluate_gating(%User{} = user) do
    case opposite_gender(user.gender) do
      nil ->
        {:ok, user}

      opposite ->
        city_count =
          if is_binary(user.city) do
            from(u in User,
              where:
                u.id != ^user.id and u.user_state == :active and u.gender == ^opposite and
                  fragment("lower(?) = lower(?)", u.city, ^user.city)
            )
            |> Repo.aggregate(:count, :id)
          else
            0
          end

        around_count =
          case Geo.point_for(user) do
            {:ok, point} ->
              from(u in User,
                where: u.id != ^user.id and u.user_state == :active and u.gender == ^opposite
              )
              |> Geo.within_radius(point, 50)
              |> Repo.aggregate(:count, :id)

            :error ->
              0
          end

        is_id_verified =
          user.aadhar_verified || user.passport_verified || user.license_verified

        days_since_creation =
          case user.inserted_at do
            %DateTime{} = inserted_at ->
              DateTime.diff(DateTime.utc_now(), inserted_at, :day) > 7

            _ ->
              false
          end

        force_verification_required =
          Features.enforce_verification_gate?() and not is_id_verified and
            days_since_creation and around_count > 50

        onetime_fees_required = user.onetime_fees_required || city_count > 250
        payment_expired? = user.onetime_fees_paid and annual_payment_expired?(user)

        onetime_fees_paid =
          if payment_expired?, do: false, else: user.onetime_fees_paid

        onetime_fees_required =
          if payment_expired?, do: true, else: onetime_fees_required

        user
        |> Ecto.Changeset.change(%{
          onetime_fees_paid: onetime_fees_paid,
          onetime_fees_required: onetime_fees_required,
          around_user_count: around_count,
          force_verification_required: force_verification_required
        })
        |> Repo.update()
    end
  end

  @doc "Refreshes gating fields, returning the original user if the evaluation fails."
  def refresh_gating(%User{} = user) do
    case evaluate_gating(user) do
      {:ok, updated} -> updated
      _ -> user
    end
  end

  defp opposite_gender("Male"), do: "Female"
  defp opposite_gender("Female"), do: "Male"
  defp opposite_gender(_gender), do: nil

  defp annual_payment_expired?(%User{last_payment_at: %DateTime{} = paid_at}) do
    DateTime.diff(DateTime.utc_now(), paid_at, :day) > 365
  end

  defp annual_payment_expired?(%User{
         last_payment_at: nil,
         date_of_last_payment: %Date{} = paid_on
       }) do
    Date.diff(Date.utc_today(), paid_on) > 365
  end

  defp annual_payment_expired?(_user), do: false

  @doc """
  Atomically updates lifestyle/profile fields and, when coordinates are
  supplied, the native PostGIS geography point.

  A coordinate-changing call is rejected while the server-side 30-day location
  cooldown is active.
  """
  def update_profile_and_location(%User{} = user, profile_attrs, coords \\ nil) do
    if coords && location_change_locked?(user) do
      {:error, :location_change_locked}
    else
      profile_changeset = User.profile_changeset(user, profile_attrs)

      core_changed? =
        Enum.any?(@core_detail_fields, &Map.has_key?(profile_changeset.changes, &1))

      if user.core_details_edited and core_changed? do
        {:error, :core_details_locked}
      else
        profile_changeset =
          if core_changed? do
            Ecto.Changeset.put_change(profile_changeset, :core_details_edited, true)
          else
            profile_changeset
          end

        result =
          Repo.transaction(fn ->
            with {:ok, updated} <- Repo.update(profile_changeset),
                 {:ok, updated} <- maybe_update_coords(updated, coords) do
              updated
            else
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)

        case result do
          {:ok, updated} -> evaluate_gating(updated)
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "Updates the primary or a purchased secondary location with its own cooldown."
  def update_location_slot(%User{} = user, slot, attrs) when is_map(attrs) do
    normalized_slot = normalize_location_slot(slot)

    if normalized_slot in [:primary, :location_2, :location_3] and
         duplicate_location?(user, normalized_slot, attrs["state"], attrs["city"]) do
      {:error, :duplicate_location}
    else
      case normalized_slot do
        :primary ->
          update_profile_and_location(
            user,
            %{"state" => attrs["state"], "city" => attrs["city"]},
            %{
              "latitude" => attrs["latitude"] || attrs["lat"],
              "longitude" => attrs["longitude"] || attrs["lng"]
            }
          )

        slot when slot in [:location_2, :location_3] ->
          update_secondary_location(user, slot, attrs)

        _ ->
          {:error, :invalid_location_slot}
      end
    end
  end

  def update_location_slot(_user, _slot, _attrs), do: {:error, :invalid_location_slot}

  defp update_secondary_location(user, slot, attrs) do
    cond do
      not User.location_active?(user, slot) ->
        {:error, :location_addon_required}

      secondary_location_locked?(user, slot) ->
        {:error, :location_change_locked}

      not valid_location_attrs?(attrs) ->
        {:error, :invalid_location}

      true ->
        {fuzzed_lat, fuzzed_lng} =
          Geo.fuzz_coordinates(
            parse_coordinate(attrs["latitude"] || attrs["lat"]),
            parse_coordinate(attrs["longitude"] || attrs["lng"])
          )

        prefix = Atom.to_string(slot)

        changes = %{
          String.to_existing_atom("#{prefix}_state") => attrs["state"],
          String.to_existing_atom("#{prefix}_city") => attrs["city"],
          String.to_existing_atom("#{prefix}_geom") => Geo.point(fuzzed_lat, fuzzed_lng),
          String.to_existing_atom("#{prefix}_last_changed_at") =>
            DateTime.utc_now() |> DateTime.truncate(:second)
        }

        user
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
        |> case do
          {:ok, updated} -> evaluate_gating(updated)
          error -> error
        end
    end
  end

  defp secondary_location_locked?(user, slot) do
    case User.location_last_changed_at(user, slot) do
      %DateTime{} = changed_at ->
        DateTime.compare(DateTime.add(changed_at, 30, :day), DateTime.utc_now()) == :gt

      _ ->
        false
    end
  end

  defp valid_location_attrs?(attrs) do
    present_string?(attrs["state"]) and present_string?(attrs["city"]) and
      is_number(parse_coordinate(attrs["latitude"] || attrs["lat"])) and
      is_number(parse_coordinate(attrs["longitude"] || attrs["lng"]))
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp parse_coordinate(value) when is_number(value), do: value * 1.0

  defp parse_coordinate(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_coordinate(_value), do: nil

  defp normalize_location_slot("primary"), do: :primary
  defp normalize_location_slot("location_1"), do: :primary
  defp normalize_location_slot("location_2"), do: :location_2
  defp normalize_location_slot(:location_2), do: :location_2
  defp normalize_location_slot("location_3"), do: :location_3
  defp normalize_location_slot(:location_3), do: :location_3
  defp normalize_location_slot(_slot), do: :invalid

  defp maybe_update_coords(user, nil), do: {:ok, user}

  defp maybe_update_coords(user, %{} = coords) do
    user
    |> User.location_changeset(%{
      latitude: coords["latitude"] || coords[:latitude],
      longitude: coords["longitude"] || coords[:longitude]
    })
    |> Repo.update()
  end

  def update_user_coordinates(user, attrs) do
    case user
         |> User.location_changeset(attrs)
         |> Repo.update() do
      {:ok, updated} -> evaluate_gating(updated)
      error -> error
    end
  end

  @doc "Delegates to the shared 5 km coordinate fuzzing boundary."
  def fuzz_coordinates(latitude, longitude),
    do: Marrylocal.Geo.fuzz_coordinates(latitude, longitude)

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
    |> where(
      [u],
      fragment(
        "ST_DWithin(ST_SetSRID(ST_MakePoint(u.longitude, u.latitude), 4326)::geography,
                    ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
        ^current_user.longitude,
        ^current_user.latitude,
        ^radius_m
      )
    )
    |> Repo.aggregate(:count, :id)
  end

  def get_usercount_by_date(date \\ Date.utc_today()) do
    from(u in User,
      # Cast the timestamp to a date in Postgres for an accurate match
      where: fragment("?::date", u.date_of_creation) == ^date
    )
    |> Repo.aggregate(:count, :id)
  end

  # function now enforces a max limit of 8 and ignores further referrals once reached.
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
      new_list = [new_email | referrer.referee_emails || []] |> Enum.uniq()

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
      nil ->
        {:error, :not_found}

      _target ->
        # Only update if the shortid is NOT already in the array
        from(u in User,
          where:
            u.id == ^current_user.id and
              fragment("NOT (? @> ARRAY[?])", u.shortlist, ^target_shortid)
        )
        |> Repo.update_all(push: [shortlist: target_shortid])

        {:ok, target_shortid}
    end
  end

  # function targets the shortlist array and removes all instances of the specific target_shortid.
  def remove_from_shortlist(current_user, target_shortid) do
    # The entire query (where + update) should be inside the from()
    query =
      from u in User,
        where: u.id == ^current_user.id,
        update: [set: [shortlist: fragment("array_remove(shortlist, ?)", ^target_shortid)]]

    Repo.update_all(query, [])

    {:ok, target_shortid}
  end

  def list_shortlisted_users1(shortid_list, params \\ %{}) do
    query =
      User
      |> where([u], u.shortid in ^shortid_list)
      # Only show active users
      |> where([u], u.user_state == :active)

    Repo.paginate(query, page: params["page"] || 1)
  end

  # Mutual Interest indicators on your shortlist
  # We use a PostgreSQL Fragment with the @> (contains) operator.
  # This allows the database to calculate the mutual status in a single pass.
  def list_shortlisted_users(current_user, params \\ %{}) do
    shortid_list = current_user.shortlist || []

    query =
      User
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

  def register_admin(attrs) do
    %User{}
    |> User.admin_registration_changeset(attrs)
    |> Repo.insert()
  end

  # Images:
  def generate_presigned_url(filename) do
    # Generate a unique path: "uploads/users/shortid/filename.jpg"
    s3_path = "uploads/#{filename}"

    # Generate a PUT URL valid for 1 hour
    {:ok, url} =
      ExAws.S3.presigned_url(
        ExAws.Config.new(:s3),
        :put,
        "your-bucket-name",
        s3_path,
        expires_in: 3600
      )

    {:ok, %{upload_url: url, public_url: "https://your-bucket.s3.amazonaws.com/#{s3_path}"}}
  end
end
