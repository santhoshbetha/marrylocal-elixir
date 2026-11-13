defmodule MarrylocalWeb.Admin.InvoiceController do
  @moduledoc "Administrative invoice search by member email, handle, or invoice number."

  use MarrylocalWeb, :controller

  import Ecto.Query, warn: false

  alias Marrylocal.Accounts.User
  alias Marrylocal.Billing.Invoice
  alias Marrylocal.Repo

  def index(conn, params) do
    invoices =
      Invoice
      |> join(:inner, [i], u in User, on: u.id == i.user_id)
      |> search(params["query"] || params["q"])
      |> order_by([i], desc: i.inserted_at, desc: i.id)
      |> limit(50)
      |> select([i, u], %{invoice: i, user: u})
      |> Repo.all()
      |> Enum.map(&serialize/1)

    json(conn, %{status: "success", data: %{invoices: invoices, count: length(invoices)}})
  end

  defp search(query, nil), do: query
  defp search(query, value) when value == "", do: query

  defp search(query, value) when is_binary(value) do
    term = value |> String.trim() |> String.trim_leading("@")
    pattern = "%" <> term <> "%"

    from([i, u] in query,
      where:
        ilike(i.invoice_number, ^pattern) or ilike(u.email, ^pattern) or
          ilike(u.user_handle, ^pattern) or ilike(u.shortid, ^pattern)
    )
  end

  defp serialize(%{invoice: invoice, user: user}) do
    %{
      id: invoice.id,
      invoice_number: invoice.invoice_number,
      item_type: invoice.item_type,
      description: invoice.description,
      base_amount_inr: decimal(invoice.base_amount_inr),
      gst_amount_inr: decimal(invoice.gst_amount_inr),
      total_amount_inr: decimal(invoice.total_amount_inr),
      period_start: invoice.period_start,
      period_end: invoice.period_end,
      payment_reference: invoice.payment_reference,
      pdf_url: invoice.pdf_url,
      status: invoice.status,
      inserted_at: invoice.inserted_at,
      user: %{
        id: user.id,
        email: user.email,
        user_handle: user.user_handle,
        shortid: user.shortid,
        first_name: user.first_name,
        last_name: user.last_name,
        city: user.city,
        state: user.state
      }
    }
  end

  defp decimal(nil), do: "0.00"
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal(value), do: to_string(value)
end
