defmodule ElixirRaft.Consensus.CommitManagerTest do
  use ExUnit.Case

  alias ElixirRaft.Consensus.CommitManager
  alias ElixirRaft.Core.{LogEntry, NodeId}
  alias ElixirRaft.Storage.LogStore

  setup do
    node_id = NodeId.generate()
    test_dir = "test/tmp/commit_manager_#{node_id}"
    File.mkdir_p!(test_dir)

    # Setup LogStore
    {:ok, log_store} = LogStore.start_link(
      node_id: node_id,
      data_dir: Path.join(test_dir, "log"),
      sync_writes: true,
      name: String.to_atom("log_store_#{node_id}")
    )

    # Setup apply callback
    test_pid = self()
    apply_callback = fn entry ->
      send(test_pid, {:applied, entry})
      :ok
    end

    # Start CommitManager
    {:ok, manager} = CommitManager.start_link(
      node_id: node_id,
      log_store: log_store,
      apply_callback: apply_callback,
      name: String.to_atom("commit_manager_#{node_id}")
    )

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{
      manager: manager,
      log_store: log_store,
      node_id: node_id,
      test_dir: test_dir
    }
  end

  describe "initialization" do
    test "starts with initial state", %{manager: manager} do
      assert {:ok, 0} = CommitManager.get_commit_index(manager)
      assert {:ok, 0} = CommitManager.get_last_applied(manager)
    end
  end

  describe "commit index updates" do
    test "updates commit index with valid entries", %{manager: manager, log_store: store} do
      # Append some entries
      for i <- 1..3 do
        entry = LogEntry.new!(i, 1, "command_#{i}")
        {:ok, _} = LogStore.append(store, entry)
      end

      # Update commit index
      :ok = CommitManager.update_commit_index(manager, 2, 1)

      # Verify commit index
      assert {:ok, 2} = CommitManager.get_commit_index(manager)

      # Verify entries were applied
      assert_receive {:applied, %LogEntry{index: 1}}
      assert_receive {:applied, %LogEntry{index: 2}}
      refute_receive {:applied, %LogEntry{index: 3}}
    end

    test "validates commit index bounds", %{manager: manager} do
      # Try to commit beyond log end
      assert {:error, :invalid_commit_index} =
        CommitManager.update_commit_index(manager, 999, 1)

      # Try to commit negative index
      assert {:error, :invalid_commit_index} =
        CommitManager.update_commit_index(manager, -1, 1)
    end
  end

  describe "majority-based commit advancement" do
    test "advances commit index with majority agreement", %{manager: manager, log_store: store} do
      # Append entries
      for i <- 1..5 do
        entry = LogEntry.new!(i, 1, "command_#{i}")
        {:ok, _} = LogStore.append(store, entry)
      end

      # Setup match index for 3 node cluster with valid NodeIds
      node2_id = NodeId.generate()
      node3_id = NodeId.generate()

      match_index = %{
        node2_id => 3,
        node3_id => 3
      }

      # Advance commit index
      :ok = CommitManager.advance_commit_index(manager, match_index, 1)

      # Verify commit index advanced to majority-agreed index
      assert {:ok, 3} = CommitManager.get_commit_index(manager)

      # Verify entries were applied
      assert_receive {:applied, %LogEntry{index: 1}}
      assert_receive {:applied, %LogEntry{index: 2}}
      assert_receive {:applied, %LogEntry{index: 3}}
      refute_receive {:applied, %LogEntry{index: 4}}
    end
  end

  describe "entry application" do
    test "handles failed applications", %{log_store: store} do
      node_id = NodeId.generate()

      # Setup failing callback
      test_pid = self()
      failing_index = 2

      failing_callback = fn entry ->
        send(test_pid, {:applied, entry})
        if entry.index == failing_index, do: {:error, :failed}, else: :ok
      end

      # Start new manager with failing callback
      {:ok, failing_manager} = CommitManager.start_link(
        node_id: node_id,
        log_store: store,
        apply_callback: failing_callback,
        name: String.to_atom("failing_manager_#{node_id}")
      )

      # Append entries
      for i <- 1..3 do
        entry = LogEntry.new!(i, 1, "command_#{i}")
        {:ok, _} = LogStore.append(store, entry)
      end

      # Try to update commit index
      {:error, :failed} = CommitManager.update_commit_index(failing_manager, 3, 1)

      # Verify entries were processed in order until failure
      assert_receive {:applied, %LogEntry{index: 1}}
      assert_receive {:applied, %LogEntry{index: 2}}  # This fails
      refute_receive {:applied, %LogEntry{index: 3}}

      # Verify state after failure - last_applied should be 1 (the last successful application)
      assert {:ok, 1} = CommitManager.get_last_applied(failing_manager)
    end
  end
end
