defmodule Marrylocal.Billing do
  @moduledoc """
  Itemized invoice ledger for the annual service fee and monthly addons.

  Amounts are stored as INR decimals. GST is always computed server-side at 18%.
  Invoice numbers are generated once and remain stable for the payment record.
  """

  import Ecto.Query, warn: false

  alias Marrylocal.Billing.Invoice
  alias Marrylocal.Repo

  @gst_rate Decimal.new("0.18")

  @addon_prices %{
    "location2" => Decimal.new("100"),
    "location_2" => Decimal.new("100"),
    "addon_location_2" => Decimal.new("100"),
    "location3" => Decimal.new("100"),
    "location_3" => Decimal.new("100"),
    "addon_location_3" => Decimal.new("100"),
    "community_search" => Decimal.new("100"),
    "addon_community" => Decimal.new("100")
  }

  @addon_descriptions %{
    "location2" => "Second Location Addon (30-Day Monthly Subscription)",
    "location_2" => "Second Location Addon (30-Day Monthly Subscription)",
    "addon_location_2" => "Second Location Addon (30-Day Monthly Subscription)",
    "location3" => "Third Location Addon (30-Day Monthly Subscription)",
    "location_3" => "Third Location Addon (30-Day Monthly Subscription)",
    "addon_location_3" => "Third Location Addon (30-Day Monthly Subscription)",
    "community_search" => "Community Search Addon (30-Day Monthly Subscription)",
    "addon_community" => "Community Search Addon (30-Day Monthly Subscription)"
  }

  def list_invoices(user_id) do
    from(i in Invoice,
      where: i.user_id == ^user_id,
      order_by: [desc: i.inserted_at, desc: i.id]
    )
    |> Repo.all()
  end

  def create_itemized_invoice(%{id: user_id} = _user, item_key, opts \\ []) do
    base = Map.get(@addon_prices, to_string(item_key), Decimal.new("0"))
    gst = Decimal.mult(base, @gst_rate) |> Decimal.round(2)
    total = Decimal.add(base, gst)
    period_start = Keyword.get(opts, :period_start, DateTime.utc_now())
    period_end = Keyword.get(opts, :period_end)

    %Invoice{}
    |> Invoice.changeset(%{
      user_id: user_id,
      invoice_number: next_invoice_number(),
      item_type: normalize_item_type(item_key),
      description:
        Keyword.get(opts, :description) || Map.get(@addon_descriptions, to_string(item_key)) ||
          "MarryLocal addon",
      base_amount_inr: base,
      gst_amount_inr: gst,
      total_amount_inr: total,
      period_start: period_start,
      period_end: period_end,
      payment_reference: Keyword.get(opts, :payment_reference),
      pdf_url: Keyword.get(opts, :pdf_url),
      status: Keyword.get(opts, :status, "paid")
    })
    |> Repo.insert()
  end

  def create_annual_fee_invoice(user, opts \\ []) do
    base =
      Decimal.new(
        to_string(Keyword.get(opts, :base_amount_inr, user.accepted_one_time_fees_amount || 500))
      )

    gst = Decimal.mult(base, @gst_rate) |> Decimal.round(2)
    total = Decimal.add(base, gst)

    %Invoice{}
    |> Invoice.changeset(%{
      user_id: user.id,
      invoice_number: next_invoice_number(),
      item_type: "annual_fee",
      description: "Annual Service Fee (12-Month Subscription)",
      base_amount_inr: base,
      gst_amount_inr: gst,
      total_amount_inr: total,
      period_start: Keyword.get(opts, :period_start, DateTime.utc_now()),
      period_end: Keyword.get(opts, :period_end),
      payment_reference: Keyword.get(opts, :payment_reference),
      pdf_url: Keyword.get(opts, :pdf_url),
      status: Keyword.get(opts, :status, "paid")
    })
    |> Repo.insert()
  end

  defp normalize_item_type("location2"), do: "addon_location_2"
  defp normalize_item_type("location_2"), do: "addon_location_2"
  defp normalize_item_type("location3"), do: "addon_location_3"
  defp normalize_item_type("location_3"), do: "addon_location_3"
  defp normalize_item_type("community_search"), do: "addon_community"
  defp normalize_item_type(value), do: to_string(value)

  defp next_invoice_number do
    year = Date.utc_today().year
    sequence = System.unique_integer([:positive, :monotonic])
    "INV-#{year}-#{String.pad_leading(Integer.to_string(rem(sequence, 1_000_000)), 6, "0")}"
  end
end
