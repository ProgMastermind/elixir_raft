import Config

# Generate UUIDs for node IDs at compile time
node_1 = "11111111-1111-1111-1111-111111111111"
node_2 = "22222222-2222-2222-2222-222222222222"
node_3 = "33333333-3333-3333-3333-333333333333"

config :elixir_raft,
  cluster_size: 3,
  peers: %{
    node_1 => {{127, 0, 0, 1}, 9001},
    node_2 => {{127, 0, 0, 1}, 9002},
    node_3 => {{127, 0, 0, 1}, 9003}
  }
