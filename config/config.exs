import Config

config :elixir_raft,
  node_config: [
    cluster_size: 5,
    election_timeout_min: 150,
    election_timeout_max: 300,
    heartbeat_interval: 50,
    max_batch_size: 1000,
    sync_writes: true
  ],
  peers: %{
    # Will be populated dynamically or through environment
  }

# Different configs for different environments
import_config "#{config_env()}.exs"
