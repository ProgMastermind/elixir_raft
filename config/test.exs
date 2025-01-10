import Config

config :elixir_raft,
  peers: %{},  # Empty for tests, will be populated per test
  node_config: [
    cluster_size: 3,
    election_timeout_min: 50,
    election_timeout_max: 100,
    heartbeat_interval: 25
  ]
