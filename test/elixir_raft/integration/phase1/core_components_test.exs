defmodule ElixirRaft.Integration.Phase1.CoreComponentsTest do
  use ExUnit.Case

  alias ElixirRaft.Core.{
    ServerState,
    Term,
    LogEntry,
    NodeId,
    ClusterConfig
  }
  alias ElixirRaft.Storage.LogStore

  @cluster_size 3

  setup do
    # Setup test directory for each test
    test_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
    test_dir = "test/tmp/#{test_id}"
    File.mkdir_p!(test_dir)

    # Initialize node IDs for a test cluster
    node_ids = for _i <- 1..@cluster_size, do: NodeId.generate()
    [main_node | other_nodes] = node_ids

    # Initialize server state
    {:ok, server_state} = ServerState.new(main_node)

    # Setup cluster configuration
    {:ok, cluster_config} = ClusterConfig.new(node_ids, server_state.current_term)

    # Setup log store
    {:ok, store} = LogStore.start_link(
      data_dir: test_dir,
      sync_writes: true,
      name: String.to_atom("store_#{main_node}")
    )

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{
      main_node: main_node,
      other_nodes: other_nodes,
      server_state: server_state,
      cluster_config: cluster_config,
      store: store,
      test_dir: test_dir
    }
  end

  describe "log management" do
    test "appending and retrieving log entries", %{store: store, server_state: state} do
      # Create test entries
      entries = for i <- 1..3 do
        {:ok, entry} = LogEntry.new(i, state.current_term, "command_#{i}")
        entry
      end

      # Append entries one by one
      Enum.each(entries, fn entry ->
        {:ok, index} = LogStore.append(store, entry)
        assert index == entry.index
      end)

      # Verify entries can be retrieved individually
      Enum.each(entries, fn entry ->
        {:ok, stored_entry} = LogStore.get_entry(store, entry.index)
        assert stored_entry.command == entry.command
        assert stored_entry.term == entry.term
      end)

      # Verify range retrieval
      {:ok, retrieved_entries} = LogStore.get_entries(store, 1, 3)
      assert length(retrieved_entries) == 3
      assert Enum.map(retrieved_entries, & &1.command) == ["command_1", "command_2", "command_3"]

      # Verify last entry info
      {:ok, {last_index, last_term}} = LogStore.get_last_entry_info(store)
      assert last_index == 3
      assert last_term == state.current_term
    end

    test "log truncation", %{store: store, server_state: state} do
      # Append 5 entries
      _entries = for i <- 1..5 do
        {:ok, entry} = LogEntry.new(i, state.current_term, "command_#{i}")
        {:ok, _} = LogStore.append(store, entry)
        entry
      end

      # Truncate after index 3
      :ok = LogStore.truncate_after(store, 3)

      # Verify entries 1-3 exist and 4-5 don't
      for i <- 1..5 do
        case LogStore.get_entry(store, i) do
          {:ok, entry} ->
            assert i <= 3
            assert entry.command == "command_#{i}"
          {:error, :not_found} ->
            assert i > 3
        end
      end
    end
  end

  describe "term management" do
    test "term transitions and validation", %{server_state: state} do
      # Test term increment
      current_term = state.current_term
      next_term = Term.increment(current_term)
      assert next_term == current_term + 1

      # Test term comparison
      assert Term.compare(next_term, current_term) == :gt
      assert Term.compare(current_term, next_term) == :lt
      assert Term.compare(current_term, current_term) == :eq

      # Test term validation
      assert {:ok, _} = Term.validate(next_term)
      assert {:error, _} = Term.validate(-1)
      assert {:error, _} = Term.validate("invalid")
    end

    test "server state term updates", %{server_state: state} do
      # Update to higher term
      higher_term = Term.increment(state.current_term)
      {:ok, new_state} = ServerState.maybe_update_term(state, higher_term)
      assert new_state.current_term == higher_term
      assert new_state.voted_for == nil
      assert new_state.role == :follower

      # Try updating to lower term (should not change)
      {:ok, unchanged_state} = ServerState.maybe_update_term(new_state, state.current_term)
      assert unchanged_state == new_state
    end
  end

  describe "cluster configuration" do
    test "cluster membership operations", %{cluster_config: config, other_nodes: other_nodes} do
      # Test initial configuration
      assert config.state == :stable
      assert MapSet.size(config.current_members) == @cluster_size

      # Test membership changes
      new_node = NodeId.generate()
      {:ok, changing_config, _entry} = ClusterConfig.begin_change(config, [new_node], [List.first(other_nodes)])

      # Verify joint consensus state
      assert match?({:joint, _, _}, changing_config.state)
      assert MapSet.member?(changing_config.pending_members, new_node)
      assert MapSet.member?(changing_config.removed_members, List.first(other_nodes))

      # Complete configuration change
      {:ok, new_config, _entry} = ClusterConfig.commit_change(changing_config)
      assert new_config.state == :stable
      assert MapSet.size(new_config.current_members) == @cluster_size # Size remains same after swap
    end

    test "quorum calculation", %{cluster_config: config} do
      # Test quorum size calculation
      assert ClusterConfig.quorum_size(config) == 2 # For 3 nodes, need 2 for majority

      # Test quorum verification
      members = MapSet.to_list(config.current_members)
      assert ClusterConfig.has_quorum?(config, MapSet.new(Enum.take(members, 2)))
      refute ClusterConfig.has_quorum?(config, MapSet.new([List.first(members)]))
    end
  end

  describe "server role state transitions" do
    test "follower to candidate transition", %{server_state: state, main_node: node_id} do
      # Initial state should be follower
      assert state.role == :follower
      assert state.current_term == 0
      assert state.voted_for == nil

      # Record vote for self (as part of becoming candidate)
      {:ok, voted_state} = ServerState.record_vote_for(state, node_id, state.current_term)
      assert voted_state.voted_for == node_id

      # Verify vote cannot be changed in same term
      other_node = NodeId.generate()
      assert {:error, "Already voted for different candidate in current term"} =
        ServerState.record_vote_for(voted_state, other_node, state.current_term)

      # Verify can vote in new term
      next_term = Term.increment(state.current_term)
      {:ok, new_term_state} = ServerState.maybe_update_term(voted_state, next_term)
      {:ok, new_voted_state} = ServerState.record_vote_for(new_term_state, other_node, next_term)
      assert new_voted_state.voted_for == other_node
      assert new_voted_state.current_term == next_term
    end

    test "handling append entries messages", %{server_state: state} do
      leader_id = NodeId.generate()

      # Record leader contact
      {:ok, updated_state} = ServerState.record_leader_contact(state, leader_id)
      assert updated_state.current_leader == leader_id
    end
  end

  describe "log entry validation" do
    test "log entry creation and validation" do
      # Test valid entry creation
      {:ok, entry} = LogEntry.new(1, 1, "test_command")
      assert entry.index == 1
      assert entry.term == 1
      assert entry.command == "test_command"

      # Test invalid entry creation
      assert {:error, _} = LogEntry.new(0, 1, "test_command") # Invalid index
      assert {:error, _} = LogEntry.new(1, -1, "test_command") # Invalid term
    end

    test "log entry comparison" do
      {:ok, entry1} = LogEntry.new(1, 1, "command1")
      {:ok, entry2} = LogEntry.new(1, 1, "command2")
      {:ok, entry3} = LogEntry.new(1, 2, "command3")

      assert LogEntry.same_entry?(entry1, entry2) # Same index and term
      refute LogEntry.same_entry?(entry1, entry3) # Different term
      assert LogEntry.more_recent_term?(entry3, entry1) # Higher term
    end
  end

  describe "message serialization" do
    test "log entry serialization" do
      {:ok, entry} = LogEntry.new(1, 1, "test_command")
      serialized = LogEntry.serialize(entry)
      {:ok, deserialized} = LogEntry.deserialize(serialized)

      assert deserialized.index == entry.index
      assert deserialized.term == entry.term
      assert deserialized.command == entry.command
    end
  end
end
