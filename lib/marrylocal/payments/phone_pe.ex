defmodule Marrylocal.Payments.PhonePe do
  @moduledoc """
  Native PhonePe PG v1 client.

  Request and callback signatures are computed server-side with SHA-256 and the
  configured salt key. No client-supplied amount or checksum is trusted.
  """

  require Logger

  @pay_path "/pg/v1/pay"

  def configured? do
    config = config()
    present?(config[:merchant_id]) and present?(config[:salt_key])
  end

  def create_order(user, amount_paise) do
    if configured?() do
      config = config()
      order_id = build_order_id()
      redirect_url = "#{Marrylocal.Accounts.frontend_url()}/paymentstatus?orderid=#{order_id}"

      payload = %{
        "merchantId" => config[:merchant_id],
        "merchantTransactionId" => order_id,
        "merchantUserId" => "USER#{user.id}",
        "amount" => amount_paise,
        "redirectUrl" => redirect_url,
        "redirectMode" => "REDIRECT",
        "callbackUrl" => callback_url(),
        "mobileNumber" => normalized_phone(user.phone_number),
        "paymentInstrument" => %{"type" => "PAY_PAGE"}
      }

      encoded_payload = payload |> Jason.encode!() |> Base.encode64()

      header =
        "#{checksum(encoded_payload <> @pay_path <> config[:salt_key])}###{config[:salt_index]}"

      case Req.post("#{config[:base_url]}#{@pay_path}",
             headers: [{"content-type", "application/json"}, {"x-verify", header}],
             json: %{"request" => encoded_payload},
             receive_timeout: 15_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          redirect_url =
            get_in(body, ["data", "instrumentResponse", "redirectInfo", "url"]) ||
              get_in(body, [:data, :instrumentResponse, :redirectInfo, :url])

          if present?(redirect_url) do
            {:ok,
             %{
               order_id: order_id,
               redirect_url: redirect_url,
               amount: amount_paise,
               payload: payload
             }}
          else
            {:error, {:missing_redirect_url, body}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:provider_error, status, body}}

        {:error, reason} ->
          Logger.warning("PhonePe order request failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  @doc "Validates the callback X-VERIFY header against the raw base64 response."
  def verify_callback(x_verify, encoded_response)
      when is_binary(x_verify) and is_binary(encoded_response) do
    config = config()
    expected = "#{checksum(encoded_response <> config[:salt_key])}###{config[:salt_index]}"
    Plug.Crypto.secure_compare(expected, x_verify)
  end

  def verify_callback(_x_verify, _encoded_response), do: false

  def decode_callback(encoded_response) when is_binary(encoded_response) do
    with {:ok, decoded} <- Base.decode64(encoded_response),
         {:ok, payload} <- Jason.decode(decoded) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_callback_payload}
    end
  end

  def decode_callback(_encoded_response), do: {:error, :invalid_callback_payload}

  def checksum(value), do: :crypto.hash(:sha256, value) |> Base.encode64()

  defp build_order_id do
    "ML#{System.system_time(:millisecond)}#{rem(System.unique_integer([:positive]), 1000)}"
  end

  defp callback_url do
    "#{MarrylocalWeb.Endpoint.url()}/api/v1/payments/phonepe/callback"
  end

  defp normalized_phone(nil), do: nil

  defp normalized_phone(phone) do
    digits = String.replace(to_string(phone), ~r/\D/, "")
    if String.length(digits) >= 10, do: String.slice(digits, -10, 10), else: digits
  end

  defp config, do: Application.get_env(:marrylocal, :phonepe, [])
  defp present?(value), do: is_binary(value) and value != ""
end
