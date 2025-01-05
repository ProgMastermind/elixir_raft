import Config

config :elixir_raft,
  cluster_size: 3


config :elixir_raft, :tcp_transport,
  recv_timeout: 5000,
  connect_timeout: 5000,
  reconnect_interval: 1000,
  max_connections: 10
