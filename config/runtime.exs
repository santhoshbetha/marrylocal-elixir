import Config

# Development convenience: `mix phx.server` does not read the git-ignored
# `.env`, so Cloudflare R2, PhonePe, and mail credentials are invisible unless
# the shell exported them. Load the file at boot for dev only. Existing
# environment variables always win, so a shell override or a deployment is never
# replaced by a stray local file. Test and prod deliberately skip this.
if config_env() == :dev do
  env_file = Path.expand("../.env", __DIR__)

  if File.exists?(env_file) do
    env_file
    |> File.stream!()
    |> Enum.each(fn line ->
      line = String.trim(line)

      if line != "" and not String.starts_with?(line, "#") do
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = value |> String.trim() |> String.trim("\"") |> String.trim("'")

            if key != "" and is_nil(System.get_env(key)) do
              System.put_env(key, value)
            end

          _no_value ->
            :ok
        end
      end
    end)
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/marrylocal start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :marrylocal, MarrylocalWeb.Endpoint, server: true
end

# Every account-facing link (confirmation, magic link, password reset) is built
# from this value. It is read at runtime so no environment-specific URL is ever
# compiled into a release.
config :marrylocal, Marrylocal.Accounts,
  frontend_url: System.get_env("FRONTEND_URL", "http://localhost:5173")

config :marrylocal, :billing,
  default_annual_fee_inr: String.to_integer(System.get_env("DEFAULT_ANNUAL_FEE_INR") || "500")

# Cloudflare R2 is S3-compatible. Values are read at runtime so dev/test can
# run without production credentials, while deployments override the account
# endpoint, bucket, and public asset host through the environment.
get_env = fn key ->
  case System.get_env(key) do
    nil -> nil
    value -> String.trim(value)
  end
end

r2_scheme = get_env.("AWS_S3_SCHEME") || "https://"

r2_host =
  get_env.("AWS_S3_HOST") ||
    get_env.("R2_ENDPOINT_HOST") ||
    "47701ef2e87f29505064cb21fd2513ed.r2.cloudflarestorage.com"

r2_bucket = get_env.("AWS_S3_BUCKET") || "marrylocal"

r2_asset_host =
  get_env.("AWS_S3_ASSET_HOST") ||
    "https://pub-772bc6927d764480ac713068077a5b1e.r2.dev"

r2_access_key_id = get_env.("AWS_ACCESS_KEY_ID") || get_env.("R2_ACCESS_KEY_ID")
r2_secret_access_key = get_env.("AWS_SECRET_ACCESS_KEY") || get_env.("R2_SECRET_ACCESS_KEY")

config :ex_aws,
  access_key_id: r2_access_key_id,
  secret_access_key: r2_secret_access_key,
  region: get_env.("AWS_REGION") || "auto"

config :ex_aws, :s3,
  scheme: r2_scheme,
  host: r2_host,
  region: get_env.("AWS_REGION") || "auto"

config :waffle,
  storage: Waffle.Storage.S3,
  bucket: r2_bucket,
  asset_host: r2_asset_host

config :marrylocal, :features,
  hide_addons_marketplace:
    System.get_env("HIDE_ADDONS_MARKPLACE") ||
      System.get_env("HIDE_ADDONS_MARKETPLACE") ||
      "true",
  enforce_verification_gate: System.get_env("ENFORCE_VERIFICATION_GATE") == "true",
  enforce_payment_gate: System.get_env("ENFORCE_PAYMENT_GATE") == "true"

config :marrylocal, :toggles,
  force_verification_override: System.get_env("FORCE_VERIFICATION_OVERRIDE") == "true"

config :marrylocal, :phonepe,
  merchant_id: System.get_env("PHONEPE_MERCHANT_ID"),
  salt_key: System.get_env("PHONEPE_SALT_KEY"),
  salt_index: System.get_env("PHONEPE_SALT_INDEX", "1"),
  base_url:
    System.get_env("PHONEPE_BASE_URL") ||
      "https://api-preprod.phonepe.com/apis/pg-sandbox"

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :marrylocal, Marrylocal.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "10"),
    ssl: true,
    ssl_opts: [verify: :verify_none],
    socket_options: [keepalive: true]

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :marrylocal, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :marrylocal, MarrylocalWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :marrylocal, MarrylocalWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :marrylocal, MarrylocalWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :marrylocal, Marrylocal.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

# Production and staging dispatch through Resend. Development and test use the
# Local/Test adapters from config.exs and config/test.exs so Playwright never
# burns real email quota.
if config_env() in [:prod, :staging] do
  config :marrylocal, Marrylocal.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")

  config :swoosh, api_client: Swoosh.ApiClient.Finch
end
