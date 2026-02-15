defmodule Marrylocal.Uploads.Media do
  import Ecto.Query
  alias ExAws.S3
  alias Marrylocal.Repo
  alias Marrylocal.Accounts.User

  @bucket "marrylocal-images"
  @public_domain "https://pub-xyz.r2.dev" # Your R2 Public Bucket URL

  def generate_upload_params(user, filename) do
    # Create a unique path using the user's shortid
    ext = Path.extname(filename)
    unique_name = "#{user.shortid}/#{Ecto.UUID.generate()}#{ext}"
    object_key = "profiles/#{unique_name}"

    # Generate the Presigned PUT URL (valid for 30 mins)
    config = ExAws.Config.new(:s3)
    {:ok, url} = S3.presigned_url(config, :put, @bucket, object_key, expires_in: 1800)

    {:ok, %{
      upload_url: url,
      image_url: "#{@public_domain}/#{object_key}"
    }}
  end

  #Adding to the images Array
  def confirm_image_upload(user, image_url) do
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(push: [images: image_url])
  end

  def delete_user_image(user, image_url) do
    # 1. Extract the "object key" from the URL
    # Example: "profiles/abc123456/uuid.jpg"
    object_key = String.replace(image_url, "https://your-public-r2-domain.com", "")

    # 2. Delete from Cloudflare R2
    ExAws.S3.delete_object("your-bucket-name", object_key)
    |> ExAws.request()

    # 3. Remove the URL from the database array
    from(u in User, where: u.id == ^user.id)
    |> Repo.update_all(pull: [images: image_url])

    :ok
  end
end
