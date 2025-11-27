import Config

# Chaos Engineering configuration
# This configuration is used to enable chaos mode in development
# for testing system resilience.

config :beamflow,
  chaos_mode: false,
  chaos_config: [
    # Probability of killing a random workflow process (0.0 to 1.0)
    kill_probability: 0.1,
    # Interval in milliseconds between chaos events
    chaos_interval: 5_000,
    # Maximum number of processes to kill per interval
    max_kills_per_interval: 3
  ]
