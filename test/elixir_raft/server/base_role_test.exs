defmodule ElixirRaft.Server.BaseRoleTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Server.BaseRole
  alias ElixirRaft.Server.BaseRole.BaseState
  alias ElixirRaft.Core.{NodeId, LogEntry}
  alias ElixirRaft.Storage.LogStore

  setup do
    # Setup a temp directory for log storage
    test_dir = "test/tmp/base_role_test_#{:rand.uniform(1000)}"
    File.mkdir_p!(test_dir)

    # Start a LogStore instance
    {:ok, log_store} = LogStore.start_link(data_dir: test_dir, sync_writes: false)

    # Generate test node IDs
    node_id = NodeId.generate()
    other_node_id = NodeId.generate()

    # Create a base state for testing
    base_state = %BaseState{
      node_id: node_id,
      current_term: 1,
      voted_for: nil,
      log_store: log_store,
      last_applied: 0,
      commit_index: 0,
      leader_id: nil
    }

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, %{
      state: base_state,
      node_id: node_id,
      other_node_id: other_node_id,
      log_store: log_store
    }}
  end

  describe "validate_term/2" do
    test "returns ok when message term equals current term", %{state: state} do
      assert {:ok, ^state} = BaseRole.validate_term(state.current_term, state)
    end

    test "returns ok when message term is lower than current term", %{state: state} do
      assert {:ok, ^state} = BaseRole.validate_term(state.current_term - 1, state)
    end

    test "transitions to follower when message term is higher", %{state: state} do
      new_term = state.current_term + 1
      assert {:transition, :follower, new_state} = BaseRole.validate_term(new_term, state)
      assert new_state.current_term == new_term
      assert new_state.voted_for == nil
      assert new_state.leader_id == nil
    end
  end

  describe "maybe_advance_commit_index/2" do
    test "doesn't advance commit index when leader commit is lower", %{state: state} do
      assert state == BaseRole.maybe_advance_commit_index(state.commit_index - 1, state)
    end

    test "advances commit index up to leader commit", %{state: state, log_store: log_store} do
      # Add some entries to the log
      {:ok, entry1} = LogEntry.new(1, 1, "cmd1")
      {:ok, entry2} = LogEntry.new(2, 1, "cmd2")
      {:ok, _} = LogStore.append(log_store, entry1)
      {:ok, _}  = LogStore.append(log_store, entry2)

      # Try to advance commit index
      new_state = BaseRole.maybe_advance_commit_index(2, state)
      assert new_state.commit_index == 2
    end

    test "advances commit index only up to last log entry", %{state: state, log_store: log_store} do
      # Add one entry to the log
      {:ok, entry} = LogEntry.new(1, 1, "cmd1")
      {:ok, _}  = LogStore.append(log_store, entry)

      # Try to advance commit index beyond log length
      new_state = BaseRole.maybe_advance_commit_index(5, state)
      assert new_state.commit_index == 1
    end
  end

  describe "is_log_up_to_date?/3" do
    test "returns true when candidate has higher term", %{state: state} do
      assert BaseRole.is_log_up_to_date?(1, 2, state)
    end

    test "returns false when candidate has lower term", %{state: state, log_store: log_store} do
      # Add entry with term 2
      {:ok, entry} = LogEntry.new(1, 2, "cmd1")
      {:ok, _}  = LogStore.append(log_store, entry)

      refute BaseRole.is_log_up_to_date?(1, 1, state)
    end

    test "compares indexes when terms are equal", %{state: state, log_store: log_store} do
      # Add entry with term 1
      {:ok, entry} = LogEntry.new(1, 1, "cmd1")
      {:ok, _}  = LogStore.append(log_store, entry)

      assert BaseRole.is_log_up_to_date?(2, 1, state)
      refute BaseRole.is_log_up_to_date?(0, 1, state)
    end
  end

  describe "verify_log_matching?/3" do
    test "returns true for empty log and prev_log_index of 0", %{state: state} do
      assert BaseRole.verify_log_matching?(0, 0, state)
    end

    test "returns true when prev entry matches", %{state: state, log_store: log_store} do
      # Add entries
      {:ok, entry1} = LogEntry.new(1, 1, "cmd1")
      {:ok, entry2} = LogEntry.new(2, 2, "cmd2")
      {:ok, _}  = LogStore.append(log_store, entry1)
      {:ok, _}  = LogStore.append(log_store, entry2)

      assert BaseRole.verify_log_matching?(2, 2, state)
    end

    test "returns false when prev entry exists but term doesn't match", %{state: state, log_store: log_store} do
      # Add entry
      {:ok, entry} = LogEntry.new(1, 1, "cmd1")
      {:ok, _}  = LogStore.append(log_store, entry)

      refute BaseRole.verify_log_matching?(1, 2, state)
    end

    test "returns false when prev entry doesn't exist", %{state: state} do
      refute BaseRole.verify_log_matching?(1, 1, state)
    end
  end
end
