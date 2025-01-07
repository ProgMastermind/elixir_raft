defmodule ElixirRaft.Integration.TransportStorageTest do
  use ExUnit.Case, async: false

  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.Storage.{StateStore, LogStore}
  alias ElixirRaft.Core.{NodeId, LogEntry}
  alias ElixirRaft.RPC.Messages

  require Logger

  @moduletag :capture_log
  @timeout 5000

  setup do
    # Create unique test directories
    test_id = System.unique_integer([:positive])
    base_dir = System.tmp_dir!()

    node1_dir = Path.join([base_dir, "raft_test_#{test_id}", "node1"])
    node2_dir = Path.join([base_dir, "raft_test_#{test_id}", "node2"])

    File.mkdir_p!(node1_dir)
    File.mkdir_p!(node2_dir)

    # Generate node IDs
    node1_id = NodeId.generate()
    node2_id = NodeId.generate()

    # Start stores for both nodes
    {:ok, state_store1} = start_state_store(node1_id, node1_dir)
    {:ok, log_store1} = start_log_store(node1_dir)

    {:ok, state_store2} = start_state_store(node2_id, node2_dir)
    {:ok, log_store2} = start_log_store(node2_dir)

    # Start transports
    transport1_name = String.to_atom("transport1_#{test_id}")
    transport2_name = String.to_atom("transport2_#{test_id}")

    {:ok, _transport1} = TcpTransport.start_link(node_id: node1_id, name: transport1_name)
    {:ok, _transport2} = TcpTransport.start_link(node_id: node2_id, name: transport2_name)

    on_exit(fn ->
      File.rm_rf!(node1_dir)
      File.rm_rf!(node2_dir)
    end)

    {
      :ok,
      %{
        node1: %{
          id: node1_id,
          transport: transport1_name,
          state_store: state_store1,
          log_store: log_store1,
          dir: node1_dir
        },
        node2: %{
          id: node2_id,
          transport: transport2_name,
          state_store: state_store2,
          log_store: log_store2,
          dir: node2_dir
        }
      }
    }
  end

  describe "leader election scenario" do
      test "successful vote request and persistent state", context do
        %{node1: n1, node2: n2} = context
        test_pid = self()

        # Start listening on node2's transport
        {:ok, {addr, port}} = TcpTransport.listen(n2.transport, [])

        # Set up message handler for node2
        TcpTransport.register_message_handler(n2.transport, fn from, data ->
                send(test_pid, {:received_n2, from, data})

                case Messages.decode(data) do
                  {:ok, %Messages.RequestVote{term: term, candidate_id: candidate_id}} ->
                    # First save the term
                    # Then save the vote
                    :ok = StateStore.save_vote(n2.state_store, candidate_id)
                    :ok = StateStore.save_term(n2.state_store, term)

                    # Create response
                    response = Messages.RequestVoteResponse.new(term, true, n2.id)
                    encoded_response = Messages.encode(response)

                    # Send response in a separate process
                    spawn(fn ->
                      TcpTransport.send(n2.transport, from, encoded_response)
                    end)

                  _ -> :ok
                end
              end)

        # Connect node1 to node2
        {:ok, _} = TcpTransport.connect(n1.transport, n2.id, {addr, port}, [])

        # Create and send vote request
        term = 5
        :ok = StateStore.save_term(n1.state_store, term)

        request = Messages.RequestVote.new(
          term,
          n1.id,
          0,  # last_log_index
          0   # last_log_term
        )

        :ok = TcpTransport.send(n1.transport, n2.id, Messages.encode(request))

        # Give some time for processing
        Process.sleep(100)

        # Verify vote request received
        assert_receive {:received_n2, sender_id, encoded_msg}, @timeout
        assert sender_id == n1.id
        assert {:ok, decoded_msg} = Messages.decode(encoded_msg)
        assert decoded_msg.term == term

        # Verify persistence
        {:ok, saved_term} = StateStore.get_current_term(n2.state_store)
        assert saved_term == term

        {:ok, voted_for} = StateStore.get_voted_for(n2.state_store)
        assert voted_for == n1.id
      end

      test "log replication with persistence", context do
        %{node1: n1, node2: n2} = context
        test_pid = self()

        # Start listening on node2's transport
        {:ok, {addr, port}} = TcpTransport.listen(n2.transport, [])

        # Set up message handler for node2
        TcpTransport.register_message_handler(n2.transport, fn from, data ->
                send(test_pid, {:received_n2, from, data})

                case Messages.decode(data) do
                  {:ok, %Messages.AppendEntries{entries: entries} = msg} when length(entries) > 0 ->
                    # Save current term first
                    :ok = StateStore.save_term(n2.state_store, msg.term)

                    # Append entries one by one and ensure success
                    results = Enum.map(entries, fn entry ->
                      LogStore.append(n2.log_store, entry)
                    end)

                    # Only return success if all appends were successful
                    success = Enum.all?(results, &(&1 == :ok))

                    # Create response
                    response = Messages.AppendEntriesResponse.new(
                      msg.term,
                      success,
                      n2.id,
                      if(success, do: length(entries), else: 0)
                    )
                    encoded_response = Messages.encode(response)

                    # Send response in a separate process
                    spawn(fn ->
                      TcpTransport.send(n2.transport, from, encoded_response)
                    end)

                  _ -> :ok
                end
              end)

        # Connect node1 to node2
        {:ok, _} = TcpTransport.connect(n1.transport, n2.id, {addr, port}, [])

        # Create and append entries to node1's log
        term = 5
        entries = [
          %LogEntry{index: 1, term: term, command: "cmd1"},
          %LogEntry{index: 2, term: term, command: "cmd2"},
          %LogEntry{index: 3, term: term, command: "cmd3"}
        ]

        # Save the term and append entries to node1's log
        :ok = StateStore.save_term(n1.state_store, term)
        Enum.each(entries, &LogStore.append(n1.log_store, &1))

        # Send append entries request
        request = Messages.AppendEntries.new(
          term,
          n1.id,
          0,  # prev_log_index
          0,  # prev_log_term
          entries,
          0   # leader_commit
        )

        :ok = TcpTransport.send(n1.transport, n2.id, Messages.encode(request))

        # Give some time for processing
        Process.sleep(100)

        # Verify append entries received
        assert_receive {:received_n2, sender_id, encoded_msg}, @timeout
        assert sender_id == n1.id
        assert {:ok, decoded_msg} = Messages.decode(encoded_msg)
        assert length(decoded_msg.entries) == 3

        # Verify log persistence on both nodes
        {:ok, n1_entries} = LogStore.get_entries(n1.log_store, 1, 3)
        {:ok, n2_entries} = LogStore.get_entries(n2.log_store, 1, 3)

        assert length(n1_entries) == 3
        assert length(n2_entries) == 3
        assert n1_entries == n2_entries

        # Verify last entry info matches
        {:ok, {n1_last_index, n1_last_term}} = LogStore.get_last_entry_info(n1.log_store)
        {:ok, {n2_last_index, n2_last_term}} = LogStore.get_last_entry_info(n2.log_store)

        assert n1_last_index == 3
        assert n2_last_index == 3
        assert n1_last_term == term
        assert n2_last_term == term
      end
    end

  # Helper functions

  defp start_state_store(node_id, data_dir) do
    name = String.to_atom("state_store_#{node_id}")
    StateStore.start_link(
      node_id: node_id,
      data_dir: data_dir,
      name: name
    )
  end

  defp start_log_store(data_dir) do
    name = String.to_atom("log_store_#{data_dir}")
    LogStore.start_link(
      data_dir: data_dir,
      name: name
    )
  end
end
