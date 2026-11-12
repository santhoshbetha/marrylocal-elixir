defmodule MarrylocalWeb.Admin.SettingsController do
  @moduledoc """
  Runtime feature settings for the admin console.

  Gate values are held in the application environment so admins can toggle
  enforcement without redeploying. Environment variables remain the boot-time
  defaults.
  """

  use MarrylocalWeb, :controller

  alias Marrylocal.Features

  def index(conn, _params) do
    json(conn, %{status: "success", data: %{settings: settings()}})
  end

  def update(conn, params) do
    verification = gate_value(params, "enforce_verification_gate", "enforce_verification")
    payment = gate_value(params, "enforce_payment_gate", "enforce_payment")

    cond do
      is_nil(verification) and is_nil(payment) ->
        invalid(conn)

      not valid_gate?(verification) or not valid_gate?(payment) ->
        invalid(conn)

      true ->
        if is_boolean(verification), do: Features.put_enforce_verification_gate(verification)
        if is_boolean(payment), do: Features.put_enforce_payment_gate(payment)

        json(conn, %{status: "success", data: %{settings: settings()}})
    end
  end

  defp settings do
    %{
      enforce_verification_gate: Features.enforce_verification_gate?(),
      enforce_payment_gate: Features.enforce_payment_gate?()
    }
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

  defp invalid(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      message:
        "Gate settings must be booleans: enforce_verification_gate and enforce_payment_gate"
    })
  end
end
