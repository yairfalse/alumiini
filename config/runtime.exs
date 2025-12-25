import Config

# Runtime configuration (read at runtime, not compile time)
if config_env() == :prod do
  config :nopea,
    enable_controller: System.get_env("NOPEA_ENABLE_CONTROLLER", "true") == "true",
    watch_namespace: System.get_env("WATCH_NAMESPACE", ""),
    # Leader election for HA deployments
    enable_leader_election:
      System.get_env("NOPEA_ENABLE_LEADER_ELECTION", "false") == "true",
    leader_lease_name:
      System.get_env("NOPEA_LEADER_LEASE_NAME", "nopea-leader-election"),
    leader_lease_duration:
      String.to_integer(System.get_env("NOPEA_LEADER_LEASE_DURATION", "15")),
    leader_renew_deadline:
      String.to_integer(System.get_env("NOPEA_LEADER_RENEW_DEADLINE", "10")),
    leader_retry_period:
      String.to_integer(System.get_env("NOPEA_LEADER_RETRY_PERIOD", "2"))
end
