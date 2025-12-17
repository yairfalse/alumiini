import Config

# Production configuration
config :nopea,
  enable_controller: true,
  watch_namespace: System.get_env("WATCH_NAMESPACE", "")

config :logger, level: :info
