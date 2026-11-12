defmodule Marrylocal.Uploaders.Invoice do
  @moduledoc """
  Waffle uploader for generated invoice PDFs stored in Cloudflare R2.
  """

  use Waffle.Definition
  use Waffle.Ecto.Definition

  @versions [:original]

  def validate({file, _transaction}) do
    Path.extname(file.file_name) |> String.downcase() == ".pdf"
  end

  def bucket do
    System.get_env("AWS_S3_BUCKET") || "marrylocal"
  end

  def filename(version, {_file, transaction}) do
    "#{version}-invoice-#{transaction.order_id}.pdf"
  end

  def storage_dir(_version, {_file, transaction}) do
    "invoices/#{transaction.user_id}"
  end

  def s3_object_headers(_version, {file, _transaction}) do
    [content_type: Map.get(file, :content_type) || "application/pdf"]
  end
end
