import Config
config :jumpstart_ai, token_signing_secret: "2Ne/TVWeZr5ZdpApMI73IeHJ/moEat5I"
config :bcrypt_elixir, log_rounds: 1
config :jumpstart_ai, Oban, testing: :manual

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :jumpstart_ai, JumpstartAi.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "jumpstart_ai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: JumpstartAi.PostgrexTypes

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :jumpstart_ai, JumpstartAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qG8xX8bgDk+ZFG6i6rA+riQTrn51MeTY2UgpLUXDHAlhXKX6sdPcAH3EQEqRAZPg",
  server: false

# In test we don't send emails
config :jumpstart_ai, JumpstartAi.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
