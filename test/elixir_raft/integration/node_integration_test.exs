defmodule ElixirRaft.Integration.NodeIntegrationTest do
  use ExUnit.Case

  alias ElixirRaft.Storage.{LogStore, StateStore}
  alias ElixirRaft.Consensus.{MessageDispatcher, CommitManager}
  alias ElixirRaft.Core.{LogEntry, Term, NodeId}
  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.RPC.Messages

  @moduletag :integration

  setup do
    # Create temporary test directory
    test_dir = Path.join(System.tmp_dir!(), "raft_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(test_dir)

    # Generate valid NodeId for tests
    {:ok, node_id} = NodeId.validate(NodeId.generate())

    # Basic configuration for tests
    config = [
      node_id: node_id,
      data_dir: test_dir,
      sync_writes: true
    ]

    on_exit(fn ->
      Process.sleep(100) # Give time for processes to stop
      File.rm_rf!(test_dir)
    end)

    {:ok, config: config, test_dir: test_dir, node_id: node_id}
  end

  describe "node lifecycle" do
    test "node startup sequence", %{config: config} do
      # Start all components in order
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      commit_config = Keyword.merge(config, [
        log_store: log_store,
        apply_callback: fn _entry -> :ok end
      ])

      {:ok, commit_manager} = CommitManager.start_link(commit_config)

      dispatcher_config = Keyword.merge(config, [
        name: String.to_atom("dispatcher_#{config[:node_id]}"),
        state_store: state_store,
        log_store: log_store
      ])

      {:ok, dispatcher} = MessageDispatcher.start_link(dispatcher_config)

      transport_config = Keyword.merge(config, [
        name: String.to_atom("transport_#{config[:node_id]}")
      ])

      {:ok, transport} = TcpTransport.start_link(transport_config)

      # Verify initial state
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)
      assert {:ok, 0} = CommitManager.get_commit_index(commit_manager)
      assert {:ok, 0} = CommitManager.get_last_applied(commit_manager)
      assert {:ok, 0} = StateStore.get_current_term(state_store)
    end

    test "state recovery after restart", %{config: config} do
      # Start components and create initial state
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      # Create and append some entries
      entries = for i <- 1..3 do
        {:ok, entry} = LogEntry.new(i, 1, {:set, "key#{i}", "value#{i}"})
        {:ok, _} = LogStore.append(log_store, entry)
        entry
      end

      # Update term and vote
      :ok = StateStore.save_term(state_store, 2)
      {:ok, voted_for} = NodeId.validate(NodeId.generate())
      :ok = StateStore.save_vote(state_store, voted_for)

      # Stop components
      :ok = GenServer.stop(state_store)
      :ok = GenServer.stop(log_store)

      # Restart components
      {:ok, recovered_log} = LogStore.start_link(config)
      {:ok, recovered_state} = StateStore.start_link(config)

      # Verify state recovery
      assert {:ok, entry} = LogStore.get_entry(recovered_log, 1)
      assert entry.command == {:set, "key1", "value1"}

      assert {:ok, 2} = StateStore.get_current_term(recovered_state)
      assert {:ok, ^voted_for} = StateStore.get_voted_for(recovered_state)
    end
  end

  describe "command processing" do
    test "log replication flow", %{config: config} do
      # Start components
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      commit_config = Keyword.merge(config, [
        log_store: log_store,
        apply_callback: fn _entry -> :ok end
      ])

      {:ok, commit_manager} = CommitManager.start_link(commit_config)

      # Create and append entries
      entries = for i <- 1..3 do
        {:ok, entry} = LogEntry.new(i, 1, {:set, "key#{i}", "value#{i}"})
        {:ok, _} = LogStore.append(log_store, entry)
        entry
      end

      # Update commit index
      :ok = CommitManager.update_commit_index(commit_manager, 2, 1)

      # Verify commit and apply status
      {:ok, commit_index} = CommitManager.get_commit_index(commit_manager)
      {:ok, last_applied} = CommitManager.get_last_applied(commit_manager)

      assert commit_index == 2
      assert last_applied == 2

      # Verify log entries
      assert {:ok, entry} = LogStore.get_entry(log_store, 2)
      assert entry.command == {:set, "key2", "value2"}
    end

    test "term and log consistency", %{config: config} do
      # Start components
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      # Save initial term
      :ok = StateStore.save_term(state_store, 1)

      # Create and append entries with different terms
      entries = [
        LogEntry.new!(1, 1, {:set, "key1", "value1"}),
        LogEntry.new!(2, 1, {:set, "key2", "value2"}),
        LogEntry.new!(3, 2, {:set, "key3", "value3"})
      ]

      Enum.each(entries, fn entry ->
        {:ok, _} = LogStore.append(log_store, entry)
      end)

      # Verify term consistency
      {:ok, current_term} = StateStore.get_current_term(state_store)
      {:ok, last_entry} = LogStore.get_last_entry_info(log_store)

      assert current_term == 1  # Term should not be automatically updated by log entries
      assert elem(last_entry, 1) == 2  # Last entry's term
    end
  end
end
