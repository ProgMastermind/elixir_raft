defmodule ElixirRaft.Integration.ComponentIntegrationTest do
  use ExUnit.Case

  alias ElixirRaft.Storage.{LogStore, StateStore}
  alias ElixirRaft.Consensus.{CommitManager, MessageDispatcher}
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
      # Cleanup any running processes
      Process.sleep(100) # Give time for processes to stop
      File.rm_rf!(test_dir)
    end)

    {:ok, config: config, test_dir: test_dir, node_id: node_id}
  end

  describe "storage layer integration" do
    test "log store and state store interaction", %{config: config} do
      # Start both storage components
      {:ok, log_store} = LogStore.start_link(config)
      {:ok, state_store} = StateStore.start_link(config)

      # Create and append a log entry
      {:ok, entry} = LogEntry.new(1, 1, {:set, "key1", "value1"})
      {:ok, _} = LogStore.append(log_store, entry)

      # Update term in state store
      :ok = StateStore.save_term(state_store, 1)

      # Verify consistency between stores
      assert {:ok, stored_entry} = LogStore.get_entry(log_store, 1)
      assert {:ok, current_term} = StateStore.get_current_term(state_store)
      assert stored_entry.term == current_term
      assert stored_entry.command == {:set, "key1", "value1"}

      # Test persistence by restarting stores
      :ok = GenServer.stop(log_store)
      :ok = GenServer.stop(state_store)

      # Restart and verify data persisted
      {:ok, log_store2} = LogStore.start_link(config)
      {:ok, state_store2} = StateStore.start_link(config)

      assert {:ok, stored_entry} = LogStore.get_entry(log_store2, 1)
      assert {:ok, current_term} = StateStore.get_current_term(state_store2)
      assert stored_entry.term == current_term
    end

    test "commit manager with storage components", %{config: config} do
      # Start storage and commit manager
      {:ok, log_store} = LogStore.start_link(config)

      commit_config = Keyword.merge(config, [
        log_store: log_store,
        apply_callback: fn _entry -> :ok end
      ])

      {:ok, commit_manager} = CommitManager.start_link(commit_config)

      # Create and append multiple entries
      entries = for i <- 1..3 do
        {:ok, entry} = LogEntry.new(i, 1, {:set, "key#{i}", "value#{i}"})
        {:ok, _} = LogStore.append(log_store, entry)
        entry
      end

      # Test commit process
      :ok = CommitManager.update_commit_index(commit_manager, 2, 1)

      # Verify commit index and last applied
      {:ok, commit_index} = CommitManager.get_commit_index(commit_manager)
      {:ok, last_applied} = CommitManager.get_last_applied(commit_manager)

      assert commit_index == 2
      assert last_applied == 2
    end

    test "persistent state recovery after crash", %{config: config} do
      # Start components and create initial state
      {:ok, log_store} = LogStore.start_link(config)
      {:ok, state_store} = StateStore.start_link(config)

      # Create some state
      {:ok, entry1} = LogEntry.new(1, 1, {:set, "key1", "value1"})
      {:ok, entry2} = LogEntry.new(2, 1, {:set, "key2", "value2"})

      {:ok, _} = LogStore.append(log_store, entry1)
      {:ok, _} = LogStore.append(log_store, entry2)
      :ok = StateStore.save_term(state_store, 1)

      # Create valid NodeId for voted_for
      {:ok, voted_for} = NodeId.validate(NodeId.generate())
      :ok = StateStore.save_vote(state_store, voted_for)

      # Simulate crash by stopping components
      :ok = GenServer.stop(log_store)
      :ok = GenServer.stop(state_store)

      # Restart components
      {:ok, recovered_log} = LogStore.start_link(config)
      {:ok, recovered_state} = StateStore.start_link(config)

      # Verify state recovery
      assert {:ok, entry1} = LogStore.get_entry(recovered_log, 1)
      assert {:ok, entry2} = LogStore.get_entry(recovered_log, 2)
      assert {:ok, 1} = StateStore.get_current_term(recovered_state)
      assert {:ok, ^voted_for} = StateStore.get_voted_for(recovered_state)
    end
  end

  describe "consensus layer integration" do
    test "message dispatcher with role handlers", %{config: config} do
      # Start required components
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      # Create complete configuration with all required components
      dispatcher_config = config
        |> Keyword.merge([
          name: String.to_atom("dispatcher_#{config[:node_id]}"),
          state_store: state_store,
          log_store: log_store  # Add log_store to config
        ])

      # Start dispatcher with complete config
      {:ok, dispatcher} = MessageDispatcher.start_link(dispatcher_config)

      # Verify initial state
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)

      # Test role transition
      :ok = MessageDispatcher.transition_to(dispatcher, :candidate)
      assert {:ok, :candidate} = MessageDispatcher.get_current_role(dispatcher)

      # Create valid NodeId for candidate
      {:ok, candidate_id} = NodeId.validate(NodeId.generate())

      # Test message handling with proper term
      {:ok, current_term} = StateStore.get_current_term(state_store)
      request_vote = Messages.RequestVote.new(
        current_term,
        candidate_id,
        0,
        0
      )

      {:ok, response} = MessageDispatcher.dispatch_message(dispatcher, request_vote)
      assert response.term == current_term
      assert response.vote_granted == false  # Should be false as we're a candidate
    end

    test "role transitions and term management", %{config: config} do
      # Start required components
      {:ok, state_store} = StateStore.start_link(config)
      {:ok, log_store} = LogStore.start_link(config)

      # Create complete configuration
      dispatcher_config = config
        |> Keyword.merge([
          name: String.to_atom("dispatcher_2_#{config[:node_id]}"),
          state_store: state_store,
          log_store: log_store  # Add log_store to config
        ])

      # Start dispatcher with complete config
      {:ok, dispatcher} = MessageDispatcher.start_link(dispatcher_config)

      # Initial state
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)
      assert {:ok, 0} = StateStore.get_current_term(state_store)

      # Transition to candidate
      :ok = MessageDispatcher.transition_to(dispatcher, :candidate)
      Process.sleep(100)  # Allow for state updates

      # Verify term increment
      {:ok, term} = StateStore.get_current_term(state_store)
      assert term > 0, "Term should be incremented after transition to candidate"

      # Verify role
      {:ok, role} = MessageDispatcher.get_current_role(dispatcher)
      assert role == :candidate
    end
  end

   describe "network layer integration" do
     test "tcp transport with peer connections", %{config: config} do
       # Start transport with unique names
       transport1_config = Keyword.merge(config, [name: String.to_atom("transport1_#{config[:node_id]}")])
       {:ok, transport1} = TcpTransport.start_link(transport1_config)

       # Create valid NodeId for peer
       {:ok, peer_id} = NodeId.validate(NodeId.generate())
       peer_config = config
         |> Keyword.put(:node_id, peer_id)
         |> Keyword.put(:name, String.to_atom("transport2_#{peer_id}"))

       {:ok, transport2} = TcpTransport.start_link(peer_config)

       # Listen on both transports
       {:ok, {_addr1, port1}} = TcpTransport.listen(transport1, [])
       {:ok, {_addr2, port2}} = TcpTransport.listen(transport2, [])

       # Connect peers
       {:ok, _} = TcpTransport.connect(transport1, peer_id, {{127, 0, 0, 1}, port2}, [])

       # Verify connection status
       assert :connected = TcpTransport.connection_status(transport1, peer_id)
     end

     test "message serialization and routing", %{config: config} do
       # Start transports with unique names
       transport1_config = Keyword.merge(config, [name: String.to_atom("transport3_#{config[:node_id]}")])
       {:ok, transport1} = TcpTransport.start_link(transport1_config)

       # Create valid NodeId for peer
       {:ok, peer_id} = NodeId.validate(NodeId.generate())
       peer_config = config
         |> Keyword.put(:node_id, peer_id)
         |> Keyword.put(:name, String.to_atom("transport4_#{peer_id}"))

       {:ok, transport2} = TcpTransport.start_link(peer_config)

       # Setup message handling
       test_pid = self()

       handler = fn node_id, message ->
         send(test_pid, {:message_received, node_id, message})
       end

       :ok = TcpTransport.register_message_handler(transport2, handler)

       # Connect and send message
       {:ok, {_addr1, port1}} = TcpTransport.listen(transport1, [])
       {:ok, {_addr2, port2}} = TcpTransport.listen(transport2, [])

       {:ok, _} = TcpTransport.connect(transport1, peer_id, {{127, 0, 0, 1}, port2}, [])

       test_message = Messages.encode("test_message")
       :ok = TcpTransport.send(transport1, peer_id, test_message)

       # Wait for message
       assert_receive {:message_received, sender_id, received_message}, 1000
       assert sender_id == config[:node_id]
     end
   end
end
