defmodule Marrylocal.Admin.Audience do
  @moduledoc """
  Shared targeting query for administrative notifications and bulk email.

  Every mode starts from active users. Location and individual modes further
  narrow the set; gender is optional across all modes.
  """

  import Ecto.Query

  alias Marrylocal.Accounts.User
  alias Marrylocal.Repo

  @doc "Builds the active-user query for the supplied targeting filters."
  def query(filters \\ %{}) do
    User
    |> where([u], u.user_state == :active)
    |> apply_target(filters)
    |> apply_gender(filters)
    |> apply_verified(filters)
  end

  @doc "Counts matching recipients without materialising the rows."
  def count(filters \\ %{}) do
    query(filters)
    |> Repo.aggregate(:count, :id)
  end

  @doc "Returns matching recipient emails, de-duplicated."
  def emails(filters \\ %{}) do
    query(filters)
    |> where([u], not is_nil(u.email) and u.email != "")
    |> select([u], u.email)
    |> distinct(true)
    |> Repo.all()
  end

  @doc "Returns matching users for batched notification insertion."
  def users(filters \\ %{}) do
    Repo.all(query(filters))
  end

  defp apply_target(query, filters) do
    case get(filters, :target_type) do
      "location" -> query |> apply_state(get(filters, :state)) |> apply_city(get(filters, :city))
      "individual" -> apply_identifiers(query, get(filters, :identifiers))
      _all -> query
    end
  end

  defp apply_state(query, state) when is_binary(state) and state not in ["", "All"] do
    where(query, [u], ilike(u.state, ^String.trim(state)))
  end

  defp apply_state(query, _state), do: query

  defp apply_city(query, city)
       when is_binary(city) and city not in ["", "All", "All Cities"] do
    where(query, [u], ilike(u.city, ^String.trim(city)))
  end

  defp apply_city(query, _city), do: query

  defp apply_identifiers(query, identifiers) do
    {emails, handles} = split_identifiers(identifiers)

    cond do
      emails != [] and handles != [] ->
        where(query, [u], u.email in ^emails or fragment("lower(?)", u.user_handle) in ^handles)

      emails != [] ->
        where(query, [u], u.email in ^emails)

      handles != [] ->
        where(query, [u], fragment("lower(?)", u.user_handle) in ^handles)

      true ->
        where(query, [u], false)
    end
  end

  defp split_identifiers(identifiers) do
    values =
      identifiers
      |> List.wrap()
      |> Enum.flat_map(fn value ->
        if is_binary(value), do: String.split(value, [";", ","], trim: true), else: []
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Enum.reduce(values, {[], []}, fn value, {emails, handles} ->
      cond do
        String.starts_with?(value, "@") ->
          {emails, [value |> String.trim_leading("@") |> String.downcase() | handles]}

        String.contains?(value, "@") ->
          {[String.downcase(value) | emails], handles}

        true ->
          {emails, [String.downcase(value) | handles]}
      end
    end)
    |> then(fn {emails, handles} -> {Enum.uniq(emails), Enum.uniq(handles)} end)
  end

  defp apply_gender(query, filters) do
    case get(filters, :gender) do
      gender when gender in ["Male", "Female"] -> where(query, [u], u.gender == ^gender)
      _ -> query
    end
  end

  defp apply_verified(query, filters) do
    if get(filters, :verified_only) in [true, "true", "1"] do
      where(query, [u], u.email_verified == true)
    else
      query
    end
  end

  defp get(filters, key) when is_map(filters) do
    Map.get(filters, key) || Map.get(filters, Atom.to_string(key))
  end
end
