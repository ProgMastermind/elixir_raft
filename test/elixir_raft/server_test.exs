defmodule ElixirRaft.ServerTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.Server
  alias ElixirRaft.Core.NodeId

  @base_dir "test/tmp/raft_server"
  @cluster_size 3

  setup do
    # Ensure clean test directory
    File.rm_rf!(@base_dir)
    File.mkdir_p!(@base_dir)

    {:ok, []}
  end

  describe "initialization" do
    test "starts successfully with valid options" do
      server = start_test_server("node_1")
      assert {:ok, state} = Server.get_server_state(server)
      assert state.node_id == "node_1"
      assert state.current_leader == nil
      assert state.current_term == 0
    end

    test "fails with invalid options" do
      assert {:error, _} = Server.start_link([])
      assert {:error, _} = Server.start_link([node_id: 123])
      assert {:error, _} = Server.start_link([node_id: "node_1", cluster_size: 0])
    end
  end

  describe "command handling" do
    test "rejects commands when no leader exists" do
      server = start_test_server("node_1")
      assert {:error, :no_leader} = Server.submit_command(server, {:set, :key1, "value1"})
    end

    test "forwards commands to leader" do
      server1 = start_test_server("node_1")
      server2 = start_test_server("node_2")

      # Make server2 the leader
      make_server_leader(server2)

      # Try submitting to follower
      assert {:error, {:not_leader, "node_2"}} =
        Server.submit_command(server1, {:set, :key1, "value1"})
    end
  end

  describe "leader election" do
    test "starts election when timeout occurs" do
      server = start_test_server("node_1")

      # Trigger election timeout
      send(server, :election_timeout)

      # Give some time for election to process
      Process.sleep(100)

      {:ok, state} = Server.get_server_state(server)
      assert state.current_term == 1
    end
  end

  describe "server state" do
    test "provides current state information" do
      server = start_test_server("node_1")

      assert {:ok, state} = Server.get_server_state(server)
      assert is_map(state)
      assert Map.has_key?(state, :node_id)
      assert Map.has_key?(state, :current_term)
      assert Map.has_key?(state, :current_leader)
      assert Map.has_key?(state, :last_applied)
      assert Map.has_key?(state, :commit_index)
    end
  end

  # Helper Functions

  defp start_test_server(node_id) do
    server = start_supervised!({
      Server,
      [
        node_id: node_id,
        cluster_size: @cluster_size,
        data_dir: Path.join(@base_dir, node_id)
      ]
    }, id: String.to_atom(node_id))

    server
  end

  defp make_server_leader(server) do
    # Simulate winning an election
    send(server, :election_timeout)
    Process.sleep(100)

    # Verify leadership
    {:ok, state} = Server.get_server_state(server)
    assert state.current_leader == state.node_id

    server
  end
end
