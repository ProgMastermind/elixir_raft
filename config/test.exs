import Config

config :elixir_raft,
  cluster_size: 3,
  node_config: [
    election_timeout_min: 150,
    election_timeout_max: 300
  ]
