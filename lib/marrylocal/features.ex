defmodule Marrylocal.Features do
  @moduledoc """
  Runtime feature flags for the premium search addon surface.

  The global marketplace flag can be disabled with HIDE_ADDONS_MARKPLACE=false
  once paid community discovery is ready for public rollout. Beta testers always
  bypass the block.
  """

  alias Marrylocal.Accounts.User

  @doc "True when the addon marketplace is globally hidden from public users."
  def hide_addons_marketplace? do
    :marrylocal
    |> Application.get_env(:features, [])
    |> Keyword.get(:hide_addons_marketplace, "true")
    |> enabled?()
  end

  @doc "Community search is available to everyone only after public rollout."
  def community_search_enabled?(%User{is_beta_tester: true}), do: true
  def community_search_enabled?(_user), do: not hide_addons_marketplace?()

  @doc """
  Master switch for the seven-day identity verification gate.

  Defaults to false so the initial launch never blocks users unless explicitly
  enabled through ENFORCE_VERIFICATION_GATE or the admin dashboard.
  """
  def enforce_verification_gate? do
    :marrylocal
    |> Application.get_env(:features, [])
    |> Keyword.get(:enforce_verification_gate, false)
    |> enabled?()
  end

  @doc "Updates the runtime verification gate without restarting the application."
  def put_enforce_verification_gate(value) when is_boolean(value) do
    features =
      :marrylocal
      |> Application.get_env(:features, [])
      |> Keyword.put(:enforce_verification_gate, value)

    Application.put_env(:marrylocal, :features, features)
    value
  end

  @doc "Master switch for annual service-fee enforcement."
  def enforce_payment_gate? do
    :marrylocal
    |> Application.get_env(:features, [])
    |> Keyword.get(:enforce_payment_gate, false)
    |> enabled?()
  end

  @doc "Updates the runtime payment gate without restarting the application."
  def put_enforce_payment_gate(value) when is_boolean(value) do
    features =
      :marrylocal
      |> Application.get_env(:features, [])
      |> Keyword.put(:enforce_payment_gate, value)

    Application.put_env(:marrylocal, :features, features)
    value
  end

  @doc """
  True only when the master payment gate is on and this non-admin user still
  owes the annual service fee.
  """
  def payment_enforcement_active?(%User{role: :admin}), do: false

  def payment_enforcement_active?(%User{} = user) do
    enforce_payment_gate?() and user.onetime_fees_required and not user.onetime_fees_paid
  end

  def payment_enforcement_active?(_user), do: false

  @doc """
  Number of days a completed identity verification stays valid.

  Admins can change this at runtime from the admin settings screen; the
  default is 730 days (two years).
  """
  def verification_validity_days do
    :marrylocal
    |> Application.get_env(:verification, [])
    |> Keyword.get(:validity_days, 730)
  end

  @doc "Updates the verification validity window without restarting the app."
  def put_verification_validity_days(value) when is_integer(value) and value > 0 do
    verification =
      :marrylocal
      |> Application.get_env(:verification, [])
      |> Keyword.put(:validity_days, value)

    Application.put_env(:marrylocal, :verification, verification)
    value
  end

  defp enabled?(value) when value in [true, "true", 1, "1"], do: true
  defp enabled?(_value), do: false
end
