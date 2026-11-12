defmodule Marrylocal.Workers.InvoiceWorker do
  @moduledoc """
  Generates a PDF invoice, stores it in Cloudflare R2 through Waffle, then
  emails it to the customer.
  """

  use Oban.Worker, queue: :invoices
  require Logger

  alias Marrylocal.Mailer
  alias Marrylocal.Payments.InvoicePdf
  alias Marrylocal.Payments.Transaction
  alias Marrylocal.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"transaction_id" => transaction_id}}) do
    case Repo.get(Transaction, transaction_id) |> Repo.preload(:user) do
      nil ->
        :ok

      %Transaction{status: "success", invoice_key: nil} = transaction ->
        generate_and_deliver(transaction)

      _transaction ->
        :ok
    end
  end

  defp generate_and_deliver(transaction) do
    pdf = InvoicePdf.render(transaction, transaction.user)
    path = Path.join(System.tmp_dir!(), "marrylocal-invoice-#{transaction.order_id}.pdf")
    File.write!(path, pdf)

    upload = %Plug.Upload{
      path: path,
      filename: "invoice-#{transaction.order_id}.pdf",
      content_type: "application/pdf"
    }

    try do
      case transaction
           |> Transaction.invoice_changeset(%{invoice_key: upload})
           |> Repo.update() do
        {:ok, updated} ->
          deliver_email(updated, path)
          :ok

        {:error, changeset} ->
          Logger.warning(
            "Could not store invoice for #{transaction.order_id}: #{inspect(changeset.errors)}"
          )

          :ok
      end
    after
      File.rm(path)
    end
  end

  defp deliver_email(transaction, path) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({"MarryLocal Billing", "billing@marrylocal.in"})
      |> Swoosh.Email.to(transaction.user.email)
      |> Swoosh.Email.subject("MarryLocal invoice #{transaction.order_id}")
      |> Swoosh.Email.text_body(
        "Your annual MarryLocal service fee payment was successful. Your invoice is attached."
      )
      |> Swoosh.Email.attachment(
        Swoosh.Attachment.new(path,
          filename: "invoice-#{transaction.order_id}.pdf",
          content_type: "application/pdf"
        )
      )

    case Mailer.deliver(email) do
      {:ok, _response} -> :ok
      {:error, reason} -> Logger.warning("Invoice email failed: #{inspect(reason)}")
    end
  end
end
