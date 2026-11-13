defmodule MarrylocalWeb.Admin.SettingsController do
  @moduledoc """
  Runtime feature settings for the admin console.

  Gate values are held in the application environment so admins can toggle
  enforcement without redeploying. Environment variables remain the boot-time
  defaults.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Admin.Audit
  alias Marrylocal.Features

  def index(conn, _params) do
    json(conn, %{status: "success", data: %{settings: settings()}})
  end

  def gating(conn, params), do: index(conn, params)

  def update(conn, params) do
    verification = gate_value(params, "enforce_verification_gate", "enforce_verification")
    payment = gate_value(params, "enforce_payment_gate", "enforce_payment")

    fee =
      get_in(params, ["settings", "default_annual_fee_inr"]) || params["default_annual_fee_inr"]

    fee = normalize_fee(fee)

    validity =
      get_in(params, ["settings", "verification_validity_days"]) ||
        params["verification_validity_days"]

    validity = normalize_validity(validity)

    cond do
      is_nil(verification) and is_nil(payment) and is_nil(fee) and is_nil(validity) ->
        invalid(conn)

      not valid_gate?(verification) or not valid_gate?(payment) or not valid_fee?(fee) or
          not valid_validity?(validity) ->
        invalid(conn)

      true ->
        if is_boolean(verification), do: Features.put_enforce_verification_gate(verification)
        if is_boolean(payment), do: Features.put_enforce_payment_gate(payment)
        if is_integer(fee), do: put_default_annual_fee(fee)

        if is_integer(validity),
          do: Features.put_verification_validity_days(validity)

        Audit.record(conn, "admin.settings.update", nil, %{
          enforce_verification_gate: verification,
          enforce_payment_gate: payment,
          default_annual_fee_inr: fee,
          verification_validity_days: validity
        })

        json(conn, %{status: "success", data: %{settings: settings()}})
    end
  end

  defp settings do
    %{
      enforce_verification_gate: Features.enforce_verification_gate?(),
      enforce_payment_gate: Features.enforce_payment_gate?(),
      default_annual_fee_inr: default_annual_fee(),
      verification_validity_days: Features.verification_validity_days()
    }
  end

  defp default_annual_fee do
    :marrylocal
    |> Application.get_env(:billing, [])
    |> Keyword.get(:default_annual_fee_inr, 500)
  end

  defp put_default_annual_fee(value) do
    billing =
      :marrylocal
      |> Application.get_env(:billing, [])
      |> Keyword.put(:default_annual_fee_inr, value)

    Application.put_env(:marrylocal, :billing, billing)
  end

  defp gate_value(params, primary, alias_key) do
    case fetch_gate(params, primary) do
      nil -> fetch_gate(params, alias_key)
      value -> value
    end
  end

  defp fetch_gate(params, key) do
    case get_in(params, ["settings", key]) do
      nil -> params[key]
      value -> value
    end
  end

  defp valid_gate?(nil), do: true
  defp valid_gate?(value), do: is_boolean(value)

  defp valid_fee?(nil), do: true
  defp valid_fee?(value) when is_integer(value) and value > 0, do: true
  defp valid_fee?(_value), do: false

  defp normalize_fee(nil), do: nil
  defp normalize_fee(value) when is_integer(value), do: value

  defp normalize_fee(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> value
    end
  end

  defp normalize_fee(value), do: value

  defp valid_validity?(nil), do: true
  defp valid_validity?(value) when is_integer(value) and value >= 1 and value <= 3650, do: true
  defp valid_validity?(_value), do: false

  defp normalize_validity(nil), do: nil
  defp normalize_validity(value) when is_integer(value), do: value

  defp normalize_validity(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> value
    end
  end

  defp normalize_validity(value), do: value

  defp invalid(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      message:
        "Settings must include booleans for gates, a positive integer default_annual_fee_inr, and verification_validity_days between 1 and 3650"
    })
  end
end
