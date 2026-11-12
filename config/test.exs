import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Oban must not start queue/peer polling loops that fight the SQL sandbox in
# tests. Manual mode plus disabled queues/plugins keeps job execution explicit
# and lets tests use Oban.Testing assertions without real Resend calls.
config :marrylocal, Oban,
  testing: :manual,
  queues: false,
  plugins: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :marrylocal, Marrylocal.Repo,
  url:
    System.get_env("E2E_DATABASE_URL") ||
      "ecto://postgres:4DAm4JB5waKNKdMw9ht5mTRv@marrylocal-e2e-even-arch-pooler.bulrush.cloud.layerbase.dev:5432/marrylocal_e2e",
  pool_size: 40,
  queue_target: 10_000,
  queue_interval: 2_000,
  ssl: true,
  ssl_opts: [verify: :verify_none],
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :marrylocal, MarrylocalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4pDYBuv9ebJzDQ/hXngboDtUh+oLFYTh04hxSjoIO0SVCzROnUbg3JfqnxtrWW9M",
  server: false

# In test we don't send emails
config :marrylocal, Marrylocal.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
