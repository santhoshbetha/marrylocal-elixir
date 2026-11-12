defmodule MarrylocalWeb.PaymentController do
  @moduledoc """
  Server-priced addon checkout initialization.

  The client sends only selected addon identifiers and chosen locations. Prices,
  GST, and totals are computed here and sent to Stripe; no client-supplied amount
  is trusted.
  """

  use MarrylocalWeb, :controller

  require Logger

  alias Marrylocal.Accounts
  alias Marrylocal.Payments
  alias Marrylocal.Payments.{PhonePe, Transaction}

  @addon_base_paise 10_000
  @gst_rate 0.18
  @addon_keys ~w(community_search location2 location3)

  def initialize_addon_checkout(conn, %{"addons" => addons}) when is_map(addons) do
    initialize_checkout_for_items(conn, addons)
  end

  def initialize_addon_checkout(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "missing_addons",
      message: "Addon selections are required."
    })
  end

  @doc "POST /api/v1/payments/initialize-checkout with an `items` map."
  def initialize_checkout(conn, %{"items" => items}) when is_map(items) do
    initialize_checkout_for_items(conn, items)
  end

  def initialize_checkout(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      status: "error",
      code: "missing_items",
      message: "Selected items are required."
    })
  end

  defp initialize_checkout_for_items(conn, addons) do
    selected = Enum.filter(@addon_keys, &selected?(&1, addons))

    if selected == [] do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        status: "error",
        code: "no_addons_selected",
        message: "Select at least one addon before checkout."
      })
    else
      pricing = build_pricing(selected, addons)

      case System.get_env("STRIPE_SECRET_KEY") do
        key when is_binary(key) and key != "" ->
          create_stripe_session(conn, key, selected, addons, pricing)

        _ ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            status: "error",
            code: "payment_provider_not_configured",
            message: "Secure checkout is not configured yet."
          })
      end
    end
  end

  @doc """
  POST /api/v1/payments/webhook

  Verified payment-provider webhook. Requires `x-payment-signature` to match
  PAYMENT_WEBHOOK_SECRET. Activation dates are always computed on the server.
  """
  def webhook(conn, params) do
    secret = System.get_env("PAYMENT_WEBHOOK_SECRET")
    provided = get_req_header(conn, "x-payment-signature") |> List.first()

    cond do
      not is_binary(secret) or secret == "" ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "error",
          code: "webhook_not_configured",
          message: "Payment webhook verification is not configured."
        })

      not Plug.Crypto.secure_compare(secret, provided || "") ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: "Invalid payment webhook signature."})

      true ->
        activate_from_webhook(conn, params)
    end
  end

  defp activate_from_webhook(conn, params) do
    items = params["items"]

    with {:ok, user_id} <- parse_user_id(params["user_id"]),
         true <- is_map(items),
         {:ok, result} <-
           Accounts.activate_subscription(user_id, items, parse_paid_date(params["paid_on"])) do
      conn
      |> put_status(:ok)
      |> json(%{
        status: "success",
        message: "Subscription activated.",
        data: %{
          user_id: user_id,
          status: result.subscription.status,
          valid_until: result.subscription.valid_until
        }
      })
    else
      false ->
        invalid_webhook(conn, "An items map is required.")

      {:error, :user_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", message: "User not found."})

      {:error, reason} ->
        invalid_webhook(conn, "Activation failed: #{inspect(reason)}")
    end
  end

  defp invalid_webhook(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "error", message: message})
  end

  @doc "POST /api/v1/payments/phonepe/order"
  def phonepe_order(conn, _params) do
    user = conn.assigns.current_user

    if PhonePe.configured?() do
      pricing = Payments.service_fee(user)

      with {:ok, order} <- PhonePe.create_order(user, pricing.total_paise),
           {:ok, transaction} <- Payments.create_pending_transaction(user, order) do
        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          data: %{
            order_id: transaction.order_id,
            redirect_url: order.redirect_url,
            amount_paise: pricing.total_paise,
            pricing: pricing
          }
        })
      else
        {:error, :not_configured} ->
          provider_not_configured(conn)

        {:error, reason} ->
          Logger.warning("PhonePe order creation failed: #{inspect(reason)}")

          conn
          |> put_status(:bad_gateway)
          |> json(%{
            status: "error",
            code: "phonepe_order_failed",
            message: "Could not create the PhonePe payment order."
          })
      end
    else
      provider_not_configured(conn)
    end
  end

  @doc "POST /api/v1/payments/phonepe/callback"
  def phonepe_callback(conn, params) do
    encoded_response = params["response"]
    x_verify = get_req_header(conn, "x-verify") |> List.first()

    cond do
      not is_binary(encoded_response) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: "Missing PhonePe response payload."})

      not PhonePe.verify_callback(x_verify, encoded_response) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: "Invalid PhonePe callback signature."})

      true ->
        with {:ok, decoded} <- PhonePe.decode_callback(encoded_response),
             {:ok, transaction} <- Payments.complete_from_callback(decoded) do
          conn
          |> put_status(:ok)
          |> json(%{
            status: "success",
            data: %{
              order_id: transaction.order_id,
              status: transaction.status,
              invoice_url: Transaction.invoice_url(transaction)
            }
          })
        else
          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", message: "Callback rejected: #{inspect(reason)}"})
        end
    end
  end

  @doc "GET /api/v1/payments/status/:order_id"
  def status(conn, %{"order_id" => order_id}) do
    user = conn.assigns.current_user

    case Payments.get_for_user(order_id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{status: "error", message: "Transaction not found."})

      %Transaction{} = transaction ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          data: %{
            order_id: transaction.order_id,
            status: transaction.status,
            amount_paise: transaction.amount,
            currency: transaction.currency,
            paid_at: transaction.paid_at,
            invoice_url: Transaction.invoice_url(transaction),
            onetime_fees_paid: user.onetime_fees_paid,
            onetime_fees_required: user.onetime_fees_required,
            force_verification_required: user.force_verification_required
          }
        })
    end
  end

  @doc "GET /api/v1/payments/transactions"
  def transactions(conn, _params) do
    user = conn.assigns.current_user

    payload =
      Payments.list_transactions(user.id)
      |> Enum.map(fn transaction ->
        %{
          id: transaction.id,
          order_id: transaction.order_id,
          provider: transaction.provider,
          status: transaction.status,
          amount_paise: transaction.amount,
          currency: transaction.currency,
          paid_at: transaction.paid_at,
          inserted_at: transaction.inserted_at,
          invoice_url: Transaction.invoice_url(transaction)
        }
      end)

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: %{transactions: payload}})
  end

  defp provider_not_configured(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      status: "error",
      code: "phonepe_not_configured",
      message: "PhonePe checkout is not configured yet."
    })
  end

  defp parse_user_id(value) when is_integer(value), do: {:ok, value}

  defp parse_user_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_user_id}
    end
  end

  defp parse_user_id(_value), do: {:error, :invalid_user_id}

  defp parse_paid_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp parse_paid_date(_value), do: Date.utc_today()

  defp create_stripe_session(conn, key, selected, addons, pricing) do
    frontend = Accounts.frontend_url()

    form = [
      {"mode", "payment"},
      {"success_url", "#{frontend}/addons?checkout=success"},
      {"cancel_url", "#{frontend}/addons?checkout=cancelled"},
      {"line_items[0][quantity]", "1"},
      {"line_items[0][price_data][currency]", "inr"},
      {"line_items[0][price_data][unit_amount]", Integer.to_string(pricing.total_paise)},
      {"line_items[0][price_data][product_data][name]", "MarryLocal add-ons"},
      {"metadata[addons]", Jason.encode!(Map.take(addons, @addon_keys))},
      {"metadata[addon_keys]", Enum.join(selected, ",")},
      {"metadata[subtotal_paise]", Integer.to_string(pricing.subtotal_paise)},
      {"metadata[gst_paise]", Integer.to_string(pricing.gst_paise)},
      {"metadata[total_paise]", Integer.to_string(pricing.total_paise)}
    ]

    case Req.post("https://api.stripe.com/v1/checkout/sessions",
           auth: {:bearer, key},
           form: form,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"url" => url}}} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "success",
          data: %{
            checkout_url: url,
            redirect_url: url,
            addons: selected,
            pricing: %{
              subtotal_paise: pricing.subtotal_paise,
              gst_paise: pricing.gst_paise,
              total_paise: pricing.total_paise,
              currency: "INR"
            }
          }
        })

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Stripe checkout session failed: #{status} #{inspect(body)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{
          status: "error",
          code: "checkout_provider_error",
          message: "Payment provider rejected the checkout request."
        })

      {:error, reason} ->
        Logger.warning("Stripe checkout request failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{
          status: "error",
          code: "checkout_provider_unavailable",
          message: "Payment provider is unavailable. Please try again."
        })
    end
  end

  defp build_pricing(selected, addons) do
    subtotal = length(selected) * @addon_base_paise
    gst = round(subtotal * @gst_rate)

    %{
      subtotal_paise: subtotal,
      gst_paise: gst,
      total_paise: subtotal + gst,
      locations: %{
        location2: Map.get(addons, "location2"),
        location3: Map.get(addons, "location3")
      }
    }
  end

  defp selected?("community_search", addons), do: addons["community_search"] == true

  defp selected?("location2", addons) do
    match?(%{"city" => city} when is_binary(city) and city != "", addons["location2"])
  end

  defp selected?("location3", addons) do
    match?(%{"city" => city} when is_binary(city) and city != "", addons["location3"])
  end

  defp selected?(_key, _addons), do: false
end
