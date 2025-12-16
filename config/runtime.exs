import Config

# Runtime configuration (read at runtime, not compile time)
if config_env() == :prod do
  config :alumiini,
    enable_controller: System.get_env("ALUMIINI_ENABLE_CONTROLLER", "true") == "true",
    watch_namespace: System.get_env("WATCH_NAMESPACE", "")
end
