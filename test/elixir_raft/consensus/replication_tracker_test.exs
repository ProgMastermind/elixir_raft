defmodule ElixirRaft.Consensus.ReplicationTrackerTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Consensus.ReplicationTracker
  alias ElixirRaft.Core.NodeId

  @cluster_size 3
  @initial_term 1
  @last_log_index 10
  @expected_next_index 11  # @last_log_index + 1

  setup do
    node_id = NodeId.generate()
    test_node_id = NodeId.generate()
    node_id3 = NodeId.generate()

    cluster_nodes = [node_id, test_node_id, node_id3]

    tracker = start_supervised!({
      ReplicationTracker,
      [
        node_id: node_id,
        cluster_size: @cluster_size,
        current_term: @initial_term,
        last_log_index: @last_log_index,
        cluster_nodes: cluster_nodes
      ]
    })
    {:ok, tracker: tracker, test_node_id: test_node_id, node_id3: node_id3}
  end

  describe "initialization" do
    test "starts with correct initial state", %{tracker: tracker, test_node_id: test_node_id} do
      assert {:ok, 0} = ReplicationTracker.get_commit_index(tracker)
      assert {:ok, @expected_next_index} = ReplicationTracker.get_next_index(tracker, test_node_id)
    end
  end

  describe "term updates" do
    test "accepts higher terms", %{tracker: tracker} do
      assert :ok = ReplicationTracker.update_term(tracker, @initial_term + 1)
    end

    test "rejects lower terms", %{tracker: tracker} do
      assert {:error, :stale_term} = ReplicationTracker.update_term(tracker, @initial_term - 1)
    end
  end

  describe "replication tracking" do
    test "updates progress on successful replication", %{tracker: tracker, test_node_id: test_node_id} do
      match_index = 5
      assert {:ok, :not_committed} =
        ReplicationTracker.record_response(tracker, test_node_id, match_index, true)
      assert {:ok, next_index} = ReplicationTracker.get_next_index(tracker, test_node_id)
      assert next_index == match_index + 1
    end

    test "decrements next_index on failed replication", %{tracker: tracker, test_node_id: test_node_id} do
      # First get the initial next_index
      {:ok, initial_next} = ReplicationTracker.get_next_index(tracker, test_node_id)
      # Record failed response
      assert {:ok, :not_committed} =
        ReplicationTracker.record_response(tracker, test_node_id, 0, false)
      # Verify next_index was decremented
      {:ok, new_next} = ReplicationTracker.get_next_index(tracker, test_node_id)
      assert new_next == initial_next - 1
    end

    test "commits entries with quorum", %{tracker: tracker, test_node_id: test_node_id, node_id3: node_id3} do
      # Simulate successful replication to a majority
      match_index = 5

      # Record response from node 2
      assert {:ok, :not_committed} =
        ReplicationTracker.record_response(tracker, test_node_id, match_index, true)
      # Record response from node 3 (achieving majority)
      assert {:ok, :committed} =
        ReplicationTracker.record_response(tracker, node_id3, match_index, true)
      # Verify commit index was updated
      assert {:ok, ^match_index} = ReplicationTracker.get_commit_index(tracker)
    end
  end

  describe "progress reset" do
    test "resets progress for all nodes", %{tracker: tracker, test_node_id: test_node_id} do
      # First record some progress
      ReplicationTracker.record_response(tracker, test_node_id, 5, true)
      # Reset progress
      new_last_index = 20
      expected_next_index = new_last_index + 1
      assert :ok = ReplicationTracker.reset_progress(tracker, new_last_index)
      # Verify next_index was reset
      {:ok, next_index} = ReplicationTracker.get_next_index(tracker, test_node_id)
      assert next_index == expected_next_index
    end
  end

  describe "error handling" do
    test "handles invalid node IDs", %{tracker: tracker} do
      assert {:error, "Invalid node ID format"} =
        ReplicationTracker.record_response(tracker, "invalid-node-id", 5, true)
    end

    test "validates match_index bounds", %{tracker: tracker, test_node_id: test_node_id} do
      assert {:error, :invalid_match_index} =
        ReplicationTracker.record_response(tracker, test_node_id, @last_log_index + 1, true)
    end
  end
end
