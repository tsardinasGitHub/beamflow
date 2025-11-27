import Config

# We only need to import the `Phoenix.Config` module
# and the `Plug.Config` module to have access to the
# configuration functions.

if config_env() == :test do
  config :beamflow, BeamflowWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4002],
    secret_key_base: "tEstSeCrEtKeYBaSeTeStSeCrEtKeYBaSeTeStSeCrEtKeYBaSeTeStSeCrEtKeY",
    server: false

  # Print only warnings and errors during test
  config :logger, level: :warning

  # Initialize plugs at runtime for faster test compilation
  config :phoenix, :plug_init_mode, :runtime

  # Mnesia test configuration (separate directory for isolation)
  config :mnesia,
    dir: ~c".mnesia/test/#{node()}"
end
