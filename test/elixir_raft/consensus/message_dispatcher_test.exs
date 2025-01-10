defmodule ElixirRaft.MessageDispatcherTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.MessageDispatcher
  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.RPC.Messages.{RequestVote, AppendEntries}
  alias ElixirRaft.Core.NodeId

  defmodule MockTransport do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    def init(opts) do
      {:ok, %{
        test_pid: opts[:test_pid],
        node_id: opts[:node_id],
        connection_status: %{},
        message_handler: nil
      }}
    end

    # Client API implementations
    def send(server, node_id, message) do
      GenServer.call(server, {:send, node_id, message})
    end

    def connect(server, node_id, address, opts) do
      GenServer.call(server, {:connect, node_id, address, opts})
    end

    def close_connection(server, node_id) do
      GenServer.call(server, {:close_connection, node_id})
    end

    def register_message_handler(server, handler) do
      GenServer.call(server, {:register_handler, handler})
    end

    def get_local_address(server) do
      GenServer.call(server, :get_local_address)
    end

    # Server callbacks
    def handle_call({:send, node_id, message}, _from, state) do
      case get_in(state.connection_status, [node_id]) do
        :connected ->
          send(state.test_pid, {:transport_send, node_id, message})
          {:reply, :ok, state}
        _ ->
          {:reply, {:error, :not_connected}, state}
      end
    end

    def handle_call({:connect, node_id, _address, _opts}, _from, state) do
      new_state = put_in(state.connection_status[node_id], :connected)
      send(state.test_pid, {:transport_connect, node_id})
      {:reply, {:ok, :fake_socket}, new_state}
    end

    def handle_call({:close_connection, node_id}, _from, state) do
      new_state = put_in(state.connection_status[node_id], :disconnected)
      send(state.test_pid, {:transport_disconnect, node_id})
      {:reply, :ok, new_state}
    end

    def handle_call({:register_handler, handler}, _from, state) do
      {:reply, :ok, %{state | message_handler: handler}}
    end

    def handle_call(:get_local_address, _from, state) do
      {:reply, {:ok, {{127, 0, 0, 1}, 9000}}, state}
    end

    # Handle cast messages
    def handle_cast({:close_connection, node_id}, state) do
      new_state = put_in(state.connection_status[node_id], :disconnected)
      send(state.test_pid, {:transport_disconnect, node_id})
      {:noreply, new_state}
    end

    def handle_cast(_msg, state) do
      {:noreply, state}
    end
  end

  setup do
    # Generate unique names for each test
    node_id = UUID.uuid4()
    peer_id = UUID.uuid4()
    transport_name = String.to_atom("transport_#{UUID.uuid4()}")
    server_name = String.to_atom("server_#{UUID.uuid4()}")
    dispatcher_name = String.to_atom("dispatcher_#{UUID.uuid4()}")

    test_pid = self()

    # Start mock transport
    {:ok, transport} = MockTransport.start_link([
      node_id: node_id,
      name: transport_name,
      test_pid: test_pid
    ])

    # Start test server process
    server = spawn_link(fn -> test_server_loop(test_pid) end)

    # Start MessageDispatcher
    {:ok, dispatcher} = MessageDispatcher.start_link([
      node_id: node_id,
      transport: transport_name,
      server: server,
      server_name: server_name,
      name: dispatcher_name
    ])

    on_exit(fn ->
      if Process.alive?(dispatcher) do
        Process.exit(dispatcher, :normal)
      end
      if Process.alive?(transport) do
        Process.exit(transport, :normal)
      end
    end)

    %{
      dispatcher: dispatcher,
      dispatcher_name: dispatcher_name,
      transport: transport,
      transport_name: transport_name,
      server: server,
      test_pid: test_pid,
      node_id: node_id,
      peer_id: peer_id
    }
  end

  describe "initialization" do
    test "starts successfully with valid options" do
      node_id = UUID.uuid4()
      transport_name = String.to_atom("transport_#{UUID.uuid4()}")
      server_name = String.to_atom("server_#{UUID.uuid4()}")
      dispatcher_name = String.to_atom("dispatcher_#{UUID.uuid4()}")

      {:ok, transport} = MockTransport.start_link([
        node_id: node_id,
        name: transport_name,
        test_pid: self()
      ])

      assert {:ok, pid} = MessageDispatcher.start_link([
        node_id: node_id,
        transport: transport_name,
        server: self(),
        server_name: server_name,
        name: dispatcher_name
      ])

      assert Process.alive?(pid)

      # Cleanup
      Process.exit(pid, :normal)
      Process.exit(transport, :normal)
    end

    test "fails to start with missing options" do
      assert {:error, _} = MessageDispatcher.start_link([])
    end
  end

  describe "message sending" do
    test "sends message to specific peer", context do
      %{dispatcher: dispatcher, peer_id: peer_id, node_id: node_id} = context

      # First connect the peer
      MessageDispatcher.connect_peer(dispatcher, {peer_id, {"127.0.0.1", 9000}})
      Process.sleep(50)

      message = AppendEntries.new(1, node_id, 0, 0, [], 0)
      MessageDispatcher.send_message(dispatcher, peer_id, message)

      assert_receive {:transport_send, ^peer_id, sent_message}
      {:ok, decoded} = Messages.decode(sent_message)
      assert decoded.term == 1
      assert decoded.leader_id == node_id
    end

    test "handles broadcast_multiple", context do
      %{dispatcher: dispatcher, peer_id: peer_id, node_id: node_id} = context

      # First connect the peer
      MessageDispatcher.connect_peer(dispatcher, {peer_id, {"127.0.0.1", 9000}})
      Process.sleep(50)

      messages = [
        {peer_id, RequestVote.new(1, node_id, 0, 0)},
        {peer_id, AppendEntries.new(1, node_id, 0, 0, [], 0)}
      ]

      MessageDispatcher.broadcast_multiple(dispatcher, messages)

      assert_receive {:transport_send, ^peer_id, message1}
      assert_receive {:transport_send, ^peer_id, message2}

      {:ok, decoded1} = Messages.decode(message1)
      {:ok, decoded2} = Messages.decode(message2)

      assert decoded1.term == 1
      assert decoded2.term == 1
    end
  end

  describe "connection management" do
    test "tracks connection status", context do
      %{dispatcher: dispatcher, peer_id: peer_id} = context

      # Initially disconnected
      assert :disconnected == MessageDispatcher.get_connection_status(dispatcher, peer_id)

      # Connect peer
      MessageDispatcher.connect_peer(dispatcher, {peer_id, {"127.0.0.1", 9000}})
      Process.sleep(50)
      assert :connected == MessageDispatcher.get_connection_status(dispatcher, peer_id)

      # Disconnect peer
      MessageDispatcher.disconnect_peer(dispatcher, peer_id)
      Process.sleep(50)
      assert :disconnected == MessageDispatcher.get_connection_status(dispatcher, peer_id)
    end
  end

  describe "message retries" do
    test "queues messages when disconnected", context do
      %{dispatcher: dispatcher, peer_id: peer_id, node_id: node_id} = context

      message = RequestVote.new(1, node_id, 0, 0)
      MessageDispatcher.send_message(dispatcher, peer_id, message)

      # Message should not be sent because peer is disconnected
      refute_receive {:transport_send, _, _}, 100

      # Connect the peer
      MessageDispatcher.connect_peer(dispatcher, {peer_id, {"127.0.0.1", 9000}})
      Process.sleep(50)

      # Should now receive the queued message
      assert_receive {:transport_send, ^peer_id, _message}, 1000
    end
  end

  defp test_server_loop(test_pid) do
    receive do
      msg ->
        send(test_pid, {:server_received, msg})
        test_server_loop(test_pid)
    end
  end
end
