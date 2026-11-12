defmodule MarrylocalWeb.BillingController do
  @moduledoc "Authenticated invoice history for annual fees and monthly addons."

  use MarrylocalWeb, :controller

  alias Marrylocal.Billing

  def invoices(conn, _params) do
    user = conn.assigns.current_user
    invoices = Billing.list_invoices(user.id) |> Enum.map(&serialize/1)

    conn
    |> put_status(:ok)
    |> json(%{status: "success", data: %{invoices: invoices}})
  end

  defp serialize(invoice) do
    %{
      id: invoice.id,
      invoice_number: invoice.invoice_number,
      item_type: invoice.item_type,
      description: invoice.description,
      base_amount_inr: money(invoice.base_amount_inr),
      gst_amount_inr: money(invoice.gst_amount_inr),
      total_amount_inr: money(invoice.total_amount_inr),
      period_start: invoice.period_start,
      period_end: invoice.period_end,
      payment_reference: invoice.payment_reference,
      pdf_url: invoice.pdf_url,
      status: invoice.status,
      inserted_at: invoice.inserted_at
    }
  end

  defp money(nil), do: "0.00"
  defp money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp money(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2)
  defp money(value), do: to_string(value)
end
