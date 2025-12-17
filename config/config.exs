import Config

# Default configuration
config :nopea,
  enable_controller: true,
  watch_namespace: "default"

# Import environment specific config
import_config "#{config_env()}.exs"
