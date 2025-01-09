defmodule ElixirRaft.Consensus.MessageDispatcherTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.Consensus.MessageDispatcher
  alias ElixirRaft.Core.{ServerState, NodeId, Term}
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.Storage.{StateStore, LogStore}
  alias ElixirRaft.Network.TcpTransport

  @moduletag :capture_log

  # Generate static UUIDs for consistent testing
  @node1_id "550e8400-e29b-41d4-a716-446655440000"
  @node2_id "550e8400-e29b-41d4-a716-446655440001"
  @node3_id "550e8400-e29b-41d4-a716-446655440002"

  setup do
    # Create temporary directory for test storage
    test_dir = System.tmp_dir!() |> Path.join("elixir_raft_test_#{:rand.uniform(1000)}")
    File.mkdir_p!(test_dir)

    # Start TCP transport for test nodes
    {:ok, transport1} = start_supervised({TcpTransport, [
      node_id: @node1_id,
      name: :"Transport1_#{:rand.uniform(1000)}"
    ]})
    {:ok, transport2} = start_supervised({TcpTransport, [
      node_id: @node2_id,
      name: :"Transport2_#{:rand.uniform(1000)}"
    ]})
    {:ok, transport3} = start_supervised({TcpTransport, [
      node_id: @node3_id,
      name: :"Transport3_#{:rand.uniform(1000)}"
    ]})

    # Start listening on random ports
    {:ok, {_addr1, port1}} = TcpTransport.listen(transport1, [])
    {:ok, {_addr2, port2}} = TcpTransport.listen(transport2, [])
    {:ok, {_addr3, port3}} = TcpTransport.listen(transport3, [])

    # Configure test peers with actual ports
    peers = %{
      @node2_id => {{127, 0, 0, 1}, port2},
      @node3_id => {{127, 0, 0, 1}, port3}
    }
    Application.put_env(:elixir_raft, :peers, peers)

    # Start the stores
    {:ok, state_store} = start_supervised({StateStore, [
      node_id: @node1_id,
      data_dir: test_dir,
      name: :"StateStore_#{:rand.uniform(1000)}"
    ]})

    {:ok, log_store} = start_supervised({LogStore, [
      data_dir: test_dir,
      name: :"LogStore_#{:rand.uniform(1000)}"
    ]})

    # Start the dispatcher
    {:ok, dispatcher} = start_supervised({MessageDispatcher, [
      node_id: @node1_id,
      state_store: state_store,
      log_store: log_store,
      name: :"Dispatcher_#{:rand.uniform(1000)}"
    ]})

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{
      dispatcher: dispatcher,
      state_store: state_store,
      log_store: log_store,
      transport1: transport1,
      transport2: transport2,
      transport3: transport3,
      ports: %{node1: port1, node2: port2, node3: port3},
      test_dir: test_dir
    }
  end

  describe "network initialization" do
    test "establishes connections with peers", %{dispatcher: dispatcher, ports: ports} do
      # Give some time for connections to establish
      Process.sleep(200)

      # Verify connections are established
      {:ok, server_state} = MessageDispatcher.get_server_state(dispatcher)
      assert server_state.node_id == @node1_id

      # Check TCP transport status
      assert_receive {:tcp_connected, @node2_id}, 1000
      assert_receive {:tcp_connected, @node3_id}, 1000
    end

    test "handles peer disconnection and reconnection", %{dispatcher: dispatcher, transport2: transport2} do
      Process.sleep(200) # Wait for initial connections

      # Simulate peer disconnect
      TcpTransport.stop(transport2)
      Process.sleep(100)

      # Start new transport for node2
      {:ok, new_transport2} = TcpTransport.start_link([
        node_id: @node2_id,
        name: :"Transport2_New_#{:rand.uniform(1000)}"
      ])

      # Should reconnect automatically
      Process.sleep(200)
      assert_receive {:tcp_connected, @node2_id}, 1000
    end
  end

  describe "network message transmission" do
    test "successfully broadcasts append entries to all peers", %{dispatcher: dispatcher} do
      # Force leader state
      force_leader_state(dispatcher)
      Process.sleep(100)

      # Submit a command which should trigger append entries
      :ok = MessageDispatcher.submit_command(dispatcher, "test_command")

      # Verify append entries messages are sent to both peers
      assert_receive {:append_entries_sent, @node2_id}, 1000
      assert_receive {:append_entries_sent, @node3_id}, 1000
    end

    test "handles request vote responses over network", %{dispatcher: dispatcher} do
      # Trigger election
      send(dispatcher, {:timeout, :election})
      Process.sleep(100)

      # Verify request vote messages are sent
      assert_receive {:request_vote_sent, @node2_id}, 1000
      assert_receive {:request_vote_sent, @node3_id}, 1000

      # Simulate responses
      response1 = %Messages.RequestVoteResponse{
             term: 1,
             vote_granted: true,
             voter_id: @node2_id
           }

           response2 = %Messages.RequestVoteResponse{
             term: 1,
             vote_granted: true,
             voter_id: @node3_id
           }

           send_message_from_peer(@node2_id, response1, dispatcher)
           send_message_from_peer(@node3_id, response2, dispatcher)

      # Should become leader after receiving majority
      Process.sleep(100)
      assert {:ok, :leader} = MessageDispatcher.get_current_role(dispatcher)
    end

    test "handles network partitions", %{dispatcher: dispatcher, transport2: transport2, transport3: transport3} do
      # Simulate network partition by stopping peer transports
      TcpTransport.stop(transport2)
      TcpTransport.stop(transport3)
      Process.sleep(100)

      # Should step down as leader if was leader
      force_leader_state(dispatcher)
      Process.sleep(500) # Wait for heartbeat timeout

      # Should revert to follower due to lack of peer communication
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)
    end
  end

  describe "message replication" do
    test "replicates entries to peers", %{dispatcher: dispatcher} do
      force_leader_state(dispatcher)
      Process.sleep(100)

      # Submit multiple commands
      commands = ["cmd1", "cmd2", "cmd3"]
      Enum.each(commands, fn cmd ->
        :ok = MessageDispatcher.submit_command(dispatcher, cmd)
      end)

      # Verify append entries are sent with correct entries
      Enum.each(1..3, fn _ ->
        assert_receive {:append_entries_sent, @node2_id}, 1000
        assert_receive {:append_entries_sent, @node3_id}, 1000
      end)
    end

    test "handles partial replication success", %{dispatcher: dispatcher} do
      force_leader_state(dispatcher)
      Process.sleep(100)

      # Submit command
      :ok = MessageDispatcher.submit_command(dispatcher, "test_command")

      # Simulate success from one peer, failure from another
      success_response = %Messages.AppendEntriesResponse{
        term: 1,
        success: true,
        match_index: 1
      }

      failure_response = %Messages.AppendEntriesResponse{
        term: 1,
        success: false,
        match_index: 0
      }

      send_message_from_peer(@node2_id, success_response, dispatcher)
      send_message_from_peer(@node3_id, failure_response, dispatcher)

      # Should retry replication to failed peer
      assert_receive {:append_entries_sent, @node3_id}, 1000
    end
  end

  # Helper functions

  defp force_leader_state(dispatcher) do
    send(dispatcher, {:timeout, :election})
        Process.sleep(50)

        response = %Messages.RequestVoteResponse{
          term: 1,
          vote_granted: true,
          voter_id: @node2_id  # Added required voter_id field
        }

        Enum.each([@node2_id, @node3_id], fn node_id ->
          # Create a response with the correct voter_id for each node
          node_response = %Messages.RequestVoteResponse{
            term: 1,
            vote_granted: true,
            voter_id: node_id
          }
          send_message_from_peer(node_id, node_response, dispatcher)
        end)

        Process.sleep(100)
  end

  defp send_message_from_peer(from_node_id, message, dispatcher) do
    {:ok, encoded} = Messages.encode(message)
    GenServer.cast(dispatcher, {:received_message, from_node_id, encoded})
  end

  # Mock transport message handlers
  def handle_transport_message(from_node_id, message_binary, test_pid) do
    try do
      message = Messages.decode!(message_binary)
      case message do
        %Messages.AppendEntries{} ->
          send(test_pid, {:append_entries_sent, from_node_id})
        %Messages.RequestVote{} ->
          send(test_pid, {:request_vote_sent, from_node_id})
        _ ->
          send(test_pid, {:message_sent, from_node_id, message})
      end
    rescue
      _ -> :ok
    end
  end
end
