# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :marrylocal, :scopes,
  user: [
    default: true,
    module: Marrylocal.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Marrylocal.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :marrylocal,
  ecto_repos: [Marrylocal.Repo],
  generators: [timestamp_type: :utc_datetime]

config :ex_aws,
  access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
  secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
  region: "auto" # Cloudflare R2 uses "auto"

config :ex_aws, :s3,
  # Format: https://<account_id>.r2.cloudflarestorage.com
  scheme: "https://",
  host: System.get_env("R2_ENDPOINT_HOST"),
  port: 443

# Configures the endpoint
config :marrylocal, MarrylocalWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MarrylocalWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Marrylocal.PubSub

config :marrylocal, Oban,
  repo: Marrylocal.Repo,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 0 * * *", Marrylocal.Workers.UnverifiedUserCleanup}, # Runs every day at midnight
      {"0 0 * * *", Marrylocal.Workers.YearlyReferralReset}, # Runs every year on January 1st
      # Standard Cron: Minute Hour Day Month Day_of_Week
      {"0 1 * * *", Marrylocal.Workers.InactivityTracker}
    ]}
  ],
  queues: [default: 10]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :marrylocal, Marrylocal.Mailer,
  adapter: Swoosh.Adapters.Local # Use Local for development

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
