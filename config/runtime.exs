import Config

# Runtime configuration (read at runtime, not compile time)
if config_env() == :prod do
  config :nopea,
    enable_controller: System.get_env("NOPEA_ENABLE_CONTROLLER", "true") == "true",
    watch_namespace: System.get_env("WATCH_NAMESPACE", "")
end
