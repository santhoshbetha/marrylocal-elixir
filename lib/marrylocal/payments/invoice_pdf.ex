defmodule Marrylocal.Payments.InvoicePdf do
  @moduledoc "Minimal single-page PDF invoice renderer."

  def render(transaction, user) do
    amount = format_amount(transaction.amount)

    lines = [
      "MarryLocal Annual Service Invoice",
      "Invoice: #{transaction.order_id}",
      "Date: #{Date.utc_today() |> Date.to_iso8601()}",
      "Customer: #{full_name(user)}",
      "Email: #{user.email || "Not provided"}",
      "Payment status: #{String.upcase(transaction.status)}",
      "Amount paid: INR #{amount}",
      "Currency: #{transaction.currency}",
      "Provider: #{transaction.provider}",
      "Thank you for using MarryLocal."
    ]

    rows =
      Enum.with_index(Enum.drop(lines, 1), 1)
      |> Enum.map(fn {line, _index} ->
        "0 -28 Td\n(#{escape(line)}) Tj"
      end)

    content =
      [
        "BT",
        "/F1 20 Tf",
        "50 790 Td",
        "(#{escape(Enum.at(lines, 0))}) Tj",
        "/F1 12 Tf"
      ] ++ rows ++ ["ET"]

    stream = Enum.join(content, "\n")

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
      "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
      "5 0 obj\n<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream\nendobj\n"
    ]

    header = "%PDF-1.4\n"

    {body, offsets, _position} =
      Enum.reduce(objects, {[], [], byte_size(header)}, fn object, {acc, offsets, position} ->
        {[object | acc], [position | offsets], position + byte_size(object)}
      end)

    body = body |> Enum.reverse() |> Enum.join()
    xref_offset = byte_size(header) + byte_size(body)
    offsets = Enum.reverse(offsets)

    xref =
      [
        "xref\n0 #{length(objects) + 1}\n",
        "0000000000 65535 f \n"
        | Enum.map(offsets, fn offset ->
            "#{String.pad_leading(Integer.to_string(offset), 10, "0")} 00000 n \n"
          end)
      ]
      |> Enum.join()

    trailer =
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"

    header <> body <> xref <> trailer
  end

  defp full_name(user) do
    [user.first_name, user.last_name]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> case do
      "" -> "MarryLocal member"
      name -> name
    end
  end

  defp format_amount(amount) when is_integer(amount) do
    :erlang.float_to_binary(amount / 100, decimals: 2)
  end

  defp format_amount(_amount), do: "0.00"

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end
end
