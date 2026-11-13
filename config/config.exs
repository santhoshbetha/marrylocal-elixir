# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Exposed so controllers can decide whether to include diagnostic details in
# error payloads. Production deployments keep internal exception messages out
# of API responses while development and test keep them visible.
config :marrylocal, :env, config_env()

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

# PostGIS geometry/geography types are decoded by a dedicated Postgrex
# extension so `Geo.Point` structs round-trip through Ecto instead of leaking
# raw WKB binaries into application code.
config :geo_postgis, json_library: Jason

config :marrylocal, Marrylocal.Repo, types: Marrylocal.PostgresTypes

# Runtime-owned account links. Production always overrides this through the
# FRONTEND_URL environment variable in config/runtime.exs.
config :marrylocal, Marrylocal.Accounts, frontend_url: "http://localhost:5173"

config :marrylocal, :billing, default_annual_fee_inr: 500

# Days a completed verification stays valid before the daily expiry sweep
# resets the member's trust flags. Overridable at runtime by admins.
config :marrylocal, :verification, validity_days: 730

config :marrylocal, :kyc, provider: "manual"

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
  queues: [default: 10, mailers: 5, invoices: 3],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Daily midnight maintenance
       {"0 0 * * *", Marrylocal.Workers.UnverifiedUserCleanup},
       {"0 0 * * *", Marrylocal.Workers.YearlyReferralReset},
       # Daily inactivity sweep
       {"0 1 * * *", Marrylocal.Workers.InactivityTracker},
       # Daily 1:30 AM UTC seed-verifier recruitment sweep
       {"30 1 * * *", Marrylocal.Workers.CitySeedRecruitmentWorker},
       # Daily 2 AM UTC check for 365-day fee resets
       {"0 2 * * *", Marrylocal.Workers.YearlySubscriptionReset},
       # Daily 4 AM UTC sweep for expired monthly location addons
       {"0 4 * * *", Marrylocal.Workers.SubscriptionExpiryWorker},
       # Daily 3 AM UTC notification retention sweep
       {"0 3 * * *", Marrylocal.Workers.NotificationCleanupWorker},
       # Daily 5 AM UTC verification-validity sweep
       {"0 5 * * *", Marrylocal.Workers.VerificationExpiryWorker}
     ]}
  ]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :marrylocal, Marrylocal.Mailer,
  # Use Local for development
  adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
