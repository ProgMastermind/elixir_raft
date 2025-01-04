import Config

config :elixir_raft, :node_config,
  listen_addr: "127.0.0.1",
  listen_port: 4040,
  node_id: "node_1",  # Default node ID
  cluster_nodes: [
    {"node_1", "127.0.0.1", 4040},
    {"node_2", "127.0.0.1", 4041},
    {"node_3", "127.0.0.1", 4042}
  ]

config :elixir_raft, :tcp_transport,
  recv_timeout: 5000,
  connect_timeout: 5000,
  reconnect_interval: 1000,
  max_connections: 10
