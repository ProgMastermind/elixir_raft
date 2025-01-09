# defmodule ElixirRaft.Integration.ElectionTest do
#   use ExUnit.Case
#   require Logger

#   alias ElixirRaft.Consensus.MessageDispatcher
#   alias ElixirRaft.Storage.{LogStore, StateStore}
#   alias ElixirRaft.Core.{NodeId}

#   @moduletag :integration

#   # Test timeouts
#   @startup_delay 100
#   @election_wait 1000
#   @stabilization_wait 2000

#   describe "cluster election" do
#     setup do
#       # Generate unique NodeIds for the cluster
#       {:ok, node_1} = NodeId.validate(NodeId.generate())
#       {:ok, node_2} = NodeId.validate(NodeId.generate())
#       {:ok, node_3} = NodeId.validate(NodeId.generate())

#       # Setup test cluster configuration
#       nodes = [node_1, node_2, node_3]
#       peers = setup_peer_config(nodes)
#       Application.put_env(:elixir_raft, :cluster_size, 3)
#       Application.put_env(:elixir_raft, :peers, peers)

#       # Create temp directories
#       base_dir = prepare_test_directories()
#       node_dirs = create_node_directories(nodes, base_dir)

#       # Start the nodes
#            case start_cluster_nodes(node_dirs) do
#              {:ok, started_nodes} ->
#                on_exit(fn ->
#                  cleanup_cluster(started_nodes, base_dir)
#                end)
#                {:ok, %{nodes: started_nodes, node_ids: nodes}}

#              {:error, reason} ->
#                {:error, reason}
#            end
#     end

#     test "should elect a leader in a three-node cluster", %{nodes: nodes} do
#       # Wait for initial startup
#       Process.sleep(@startup_delay)
#       Logger.info("Cluster started, waiting for election...")

#       # Wait for election to complete
#       Process.sleep(@election_wait)

#       # Get cluster status
#       cluster_status = get_cluster_status(nodes)
#       Logger.info("Cluster status after election: #{inspect(cluster_status, pretty: true)}")

#       # Verify leader election
#       assert_leader_election(cluster_status)

#       # Wait for cluster to stabilize
#       Process.sleep(@stabilization_wait)

#       # Verify cluster stability
#       final_status = get_cluster_status(nodes)
#       Logger.info("Final cluster status: #{inspect(final_status, pretty: true)}")
#       # assert_stable_cluster(final_status)
#     end

#     test "should re-elect leader when current leader fails", %{nodes: nodes} do
#       # Wait for initial election
#       Process.sleep(@election_wait)
#       initial_status = get_cluster_status(nodes)
#       {leader_id, leader_pid} = find_leader(initial_status)
#       Logger.info("Initial leader: #{inspect(leader_id)}")

#       # Kill the leader
#       Process.exit(leader_pid, :kill)
#       Logger.info("Killed leader, waiting for re-election...")

#       # Wait for new election
#       Process.sleep(@election_wait)

#       # Get new cluster status
#       new_status = get_cluster_status(Map.delete(nodes, leader_id))
#       Logger.info("Cluster status after re-election: #{inspect(new_status, pretty: true)}")

#       # Verify new leader election
#       assert_new_leader_election(new_status, leader_id)
#     end
#   end

#   # Helper Functions

#   defp setup_peer_config(nodes) do
#       # Start with higher ports to avoid conflicts
#       nodes
#       |> Enum.with_index(1)
#       |> Enum.map(fn {node_id, index} ->
#         {node_id, {{127, 0, 0, 1}, 19000 + index}}
#       end)
#       |> Map.new()
#     end

#   defp prepare_test_directories do
#     base_dir = Path.join([System.tmp_dir!(), "raft_test_#{:rand.uniform(1000)}"])
#     File.rm_rf!(base_dir)
#     File.mkdir_p!(base_dir)
#     base_dir
#   end

#   defp create_node_directories(nodes, base_dir) do
#     nodes
#     |> Enum.map(fn node_id ->
#       dir = Path.join(base_dir, node_id)
#       File.mkdir_p!(dir)
#       {node_id, dir}
#     end)
#     |> Map.new()
#   end

#   defp start_cluster_nodes(node_dirs) do
#       nodes = Enum.map(node_dirs, fn {node_id, dir} ->
#         # Start components with unique names
#         log_store_name = String.to_atom("log_store_#{node_id}")
#         state_store_name = String.to_atom("state_store_#{node_id}")
#         dispatcher_name = String.to_atom("dispatcher_#{node_id}")

#         # Start TcpTransport first
#         {:ok, transport} = ElixirRaft.Network.TcpTransport.start_link([
#           node_id: node_id,
#           name: String.to_atom("transport_#{node_id}")
#         ])

#         # Get the peer config
#         peer_address = get_in(Application.get_env(:elixir_raft, :peers), [node_id])
#         :ok = ElixirRaft.Network.TcpTransport.listen(transport, [port: elem(peer_address, 1)])

#         # Start storage components
#         {:ok, log_store} = LogStore.start_link([
#           node_id: node_id,
#           data_dir: Path.join(dir, "log"),
#           name: log_store_name
#         ])

#         {:ok, state_store} = StateStore.start_link([
#           node_id: node_id,
#           data_dir: Path.join(dir, "state"),
#           name: state_store_name
#         ])

#         # Start message dispatcher
#         {:ok, dispatcher} = MessageDispatcher.start_link([
#           node_id: node_id,
#           log_store: log_store,
#           state_store: state_store,
#           transport: transport,
#           name: dispatcher_name
#         ])

#         {node_id, dispatcher}
#       end)

#       {:ok, Map.new(nodes)}
#     end

#     defp cleanup_cluster(nodes, base_dir) do
#       Enum.each(nodes, fn {_id, pid} ->
#         if Process.alive?(pid), do: GenServer.stop(pid)
#       end)
#       File.rm_rf!(base_dir)
#     end

#   defp get_cluster_status(nodes) do
#     Enum.map(nodes, fn {node_id, pid} ->
#       {:ok, role} = MessageDispatcher.get_current_role(pid)
#       {:ok, state} = MessageDispatcher.get_server_state(pid)

#       {node_id, %{
#         role: role,
#         term: state.current_term,
#         voted_for: state.voted_for,
#         leader: state.current_leader
#       }}
#     end)
#     |> Map.new()
#   end

#   defp find_leader(cluster_status) do
#     Enum.find(cluster_status, fn {_node_id, status} ->
#       status.role == :leader
#     end)
#   end

#   defp assert_leader_election(cluster_status) do
#     leaders = Enum.filter(cluster_status, fn {_id, status} ->
#       status.role == :leader
#     end)

#     followers = Enum.filter(cluster_status, fn {_id, status} ->
#       status.role == :follower
#     end)

#     assert length(leaders) == 1, "Expected exactly one leader"
#     assert length(followers) == 2, "Expected exactly two followers"

#     {leader_id, leader_status} = Enum.at(leaders, 0)

#     # Verify all nodes are in the same term
#     term = leader_status.term
#     Enum.each(cluster_status, fn {_id, status} ->
#       assert status.term == term, "Terms don't match across nodes"
#     end)

#     # Verify all followers recognize the leader
#     Enum.each(followers, fn {_id, status} ->
#       assert status.leader == leader_id, "Follower doesn't recognize correct leader"
#     end)
#   end

#   defp assert_new_leader_election(new_status, old_leader_id) do
#     # Verify new leader was elected
#     {new_leader_id, _} = find_leader(new_status)
#     assert new_leader_id != old_leader_id, "Old leader was re-elected"

#     # Verify remaining nodes are followers
#     followers = Enum.filter(new_status, fn {id, status} ->
#       id != new_leader_id && status.role == :follower
#     end)
#     assert length(followers) == 1, "Expected one follower after re-election"

#     # Verify term was incremented
#     Enum.each(new_status, fn {_id, status} ->
#       assert status.term > 0, "Term should be incremented after re-election"
#     end)
#   end
# end
