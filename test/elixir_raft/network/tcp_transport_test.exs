defmodule ElixirRaft.Network.TcpTransportTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.Core.NodeId
  require Logger

  @moduletag :capture_log
  @connection_timeout 1000
  @message_timeout 2000
  @setup_delay 100

  setup do
    test_id = System.unique_integer([:positive])

    transport1_name = String.to_atom("transport1_#{test_id}")
    transport2_name = String.to_atom("transport2_#{test_id}")

    # Generate proper NodeIds instead of strings
    node1_id = NodeId.generate()
    node2_id = NodeId.generate()

    start_opts1 = [
      node_id: node1_id,
      name: transport1_name
    ]

    start_opts2 = [
      node_id: node2_id,
      name: transport2_name
    ]

    {:ok, pid1} = GenServer.start_link(TcpTransport, start_opts1, name: transport1_name)
    {:ok, pid2} = GenServer.start_link(TcpTransport, start_opts2, name: transport2_name)

    on_exit(fn ->
      if Process.alive?(pid1), do: GenServer.stop(pid1)
      if Process.alive?(pid2), do: GenServer.stop(pid2)
    end)

    {:ok, %{
      transport1: transport1_name,
      transport2: transport2_name,
      node1_id: node1_id,
      node2_id: node2_id,
      pid1: pid1,
      pid2: pid2
    }}
  end

  describe "basic TCP transport" do
    test "can start and listen", %{transport1: transport} do
      assert {:ok, {_addr, port}} = TcpTransport.listen(transport, [])
      assert port > 0
    end

    test "can connect and send messages bi-directionally", context do
      %{
        transport1: t1,
        transport2: t2,
        node1_id: node1_id,
        node2_id: node2_id
      } = context

      test_pid = self()

      # Setup message handlers with explicit logging
      handler1 = fn node_id, msg ->
        Logger.debug("T1 received message from #{inspect(node_id)}: #{inspect(msg)}")
        send(test_pid, {:received_t1, node_id, msg})
      end

      handler2 = fn node_id, msg ->
        Logger.debug("T2 received message from #{inspect(node_id)}: #{inspect(msg)}")
        send(test_pid, {:received_t2, node_id, msg})
      end

      :ok = TcpTransport.register_message_handler(t1, handler1)
      :ok = TcpTransport.register_message_handler(t2, handler2)

      # Start listening on transport1
      {:ok, {addr, port}} = TcpTransport.listen(t1, [])
      Process.sleep(@setup_delay)

      # Connect transport2 to transport1
      {:ok, _socket} = TcpTransport.connect(t2, node1_id, {addr, port}, [])

      # Wait for both sides to be connected
      assert wait_until(fn ->
        status1 = TcpTransport.connection_status(t1, node2_id)
        status2 = TcpTransport.connection_status(t2, node1_id)
        Logger.debug("Connection status - T1->T2: #{status1}, T2->T1: #{status2}")
        status1 == :connected && status2 == :connected
      end) == :ok

      Process.sleep(@setup_delay)

      # Send test messages in both directions
      Logger.debug("Sending message from T2 to T1")
      :ok = TcpTransport.send(t2, node1_id, "hello")
      Process.sleep(50)  # Small delay between sends

      Logger.debug("Sending message from T1 to T2")
      :ok = TcpTransport.send(t1, node2_id, "world")

      # Wait for and verify both messages
      assert_receive {:received_t1, ^node2_id, "hello"}, @message_timeout
      assert_receive {:received_t2, ^node1_id, "world"}, @message_timeout
    end

    test "returns error when connecting to non-existent server", %{transport1: transport} do
      invalid_node_id = NodeId.generate()
      result = TcpTransport.connect(
        transport,
        invalid_node_id,
        {{127, 0, 0, 1}, 1},
        []
      )

      assert {:error, _} = result
    end

    test "maintains accurate connection status", context do
      %{
        transport1: t1,
        transport2: t2,
        node1_id: node1_id
      } = context

      # Initial state should be disconnected
      assert :disconnected = TcpTransport.connection_status(t2, node1_id)

      # Start listening and connect
      {:ok, {addr, port}} = TcpTransport.listen(t1, [])
      {:ok, _} = TcpTransport.connect(t2, node1_id, {addr, port}, [])

      # Wait for and verify connected status
      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :connected
      end) == :ok

      # Close connection and verify disconnected status
      TcpTransport.close_connection(t2, node1_id)
      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :disconnected
      end) == :ok
    end

    test "properly handles reconnection after closure", context do
      %{
        transport1: t1,
        transport2: t2,
        node1_id: node1_id
      } = context

      {:ok, {addr, port}} = TcpTransport.listen(t1, [])

      # First connection
      {:ok, _} = TcpTransport.connect(t2, node1_id, {addr, port}, [])
      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :connected
      end) == :ok

      # Close connection
      TcpTransport.close_connection(t2, node1_id)
      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :disconnected
      end) == :ok

      # Reconnect and verify
      assert {:ok, _} = TcpTransport.connect(t2, node1_id, {addr, port}, [])
      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :connected
      end) == :ok
    end
  end

  describe "error handling" do
    test "rejects messages exceeding size limit", context do
      %{
        transport1: t1,
        transport2: t2,
        node1_id: node1_id
      } = context

      {:ok, {addr, port}} = TcpTransport.listen(t1, [])
      {:ok, _} = TcpTransport.connect(t2, node1_id, {addr, port}, [])

      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :connected
      end) == :ok

      # Try sending message larger than 1MB
      large_message = String.duplicate("a", 2_000_000)
      assert {:error, :message_too_large} = TcpTransport.send(t2, node1_id, large_message)
    end

    test "handles peer disconnection gracefully", context do
      %{
        transport1: t1,
        transport2: t2,
        node1_id: node1_id,
        pid1: pid1
      } = context

      {:ok, {addr, port}} = TcpTransport.listen(t1, [])
      {:ok, _} = TcpTransport.connect(t2, node1_id, {addr, port}, [])

      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :connected
      end) == :ok

      # Stop transport1 to simulate peer disconnection
      GenServer.stop(pid1)

      assert wait_until(fn ->
        TcpTransport.connection_status(t2, node1_id) == :disconnected
      end) == :ok
    end

    test "returns error when sending to disconnected node", context do
      %{
        transport1: t1,
        node1_id: node1_id
      } = context

      assert {:error, :not_connected} = TcpTransport.send(t1, node1_id, "test message")
    end
  end

  describe "address management" do
    test "returns correct local address after listening", %{transport1: transport} do
      # Before listening
      assert {:error, :not_listening} = TcpTransport.get_local_address(transport)

      # After listening
      {:ok, {addr, port}} = TcpTransport.listen(transport, [])
      assert {:ok, {^addr, ^port}} = TcpTransport.get_local_address(transport)
    end
  end

  # Helper Functions

  defp wait_until(func, timeout \\ @connection_timeout, interval \\ 10) do
    if func.() do
      :ok
    else
      if timeout > 0 do
        Process.sleep(interval)
        wait_until(func, timeout - interval, interval)
      else
        {:error, :timeout}
      end
    end
  end
end
