defmodule ElixirRaft.Network.PeerTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Network.{Peer, TcpTransport}
  require Logger

  @moduletag :capture_log
  @connection_timeout 1000
  @setup_delay 100

  setup do
    test_id = System.unique_integer([:positive])

    # Setup transport for peer testing
    transport_name = String.to_atom("transport_#{test_id}")
    peer_id = "peer_#{test_id}"

    # Start transport
    {:ok, transport} = GenServer.start_link(TcpTransport, [
      node_id: "node_#{test_id}",
      name: transport_name
    ], name: transport_name)

    on_exit(fn ->
      if Process.alive?(transport), do: GenServer.stop(transport)
    end)

    {:ok, %{
      transport: transport_name,
      transport_pid: transport,
      peer_id: peer_id
    }}
  end

  describe "peer initialization" do
    test "starts with valid configuration", %{transport: transport, peer_id: peer_id} do
      {:ok, peer} = Peer.start_link([
        node_id: peer_id,
        transport: transport,
        address: {{127, 0, 0, 1}, 9000}
      ])

      assert Process.alive?(peer)
      assert {:ok, :disconnected} = Peer.get_status(peer)

      if Process.alive?(peer), do: GenServer.stop(peer)
    end

    test "fails with invalid configuration", %{transport: transport} do
      Process.flag(:trap_exit, true)  # Add this line at the start of the test

      # Missing node_id
      assert {:error, {:shutdown, {:error, :missing_required_options}}} =
        GenServer.start_link(Peer, [
          transport: transport,
          address: {{127, 0, 0, 1}, 9000}
        ])

      # Missing transport
      assert {:error, {:shutdown, {:error, :missing_required_options}}} =
        GenServer.start_link(Peer, [
          node_id: "test_peer",
          address: {{127, 0, 0, 1}, 9000}
        ])

      # Missing address
      assert {:error, {:shutdown, {:error, :missing_required_options}}} =
        GenServer.start_link(Peer, [
          node_id: "test_peer",
          transport: transport
        ])
    end
  end

  describe "connection management" do
    test "connects to remote peer", context do
      %{transport: transport1, peer_id: peer_id} = context

      # Start another transport for the remote peer
      test_id = System.unique_integer([:positive])
      transport2_name = String.to_atom("transport2_#{test_id}")
      {:ok, transport2} = GenServer.start_link(TcpTransport, [
        node_id: "remote_#{test_id}",
        name: transport2_name
      ], name: transport2_name)

      # Start listening on transport2
      {:ok, {addr, port}} = TcpTransport.listen(transport2_name, [])
      Process.sleep(@setup_delay)

      # Start peer with transport1
      {:ok, peer} = GenServer.start_link(Peer, [
        node_id: peer_id,
        transport: transport1,
        address: {addr, port}
      ])

      # Initiate connection
      :ok = Peer.connect(peer)

      # Wait for connection to establish
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :connected
      end)

      # Cleanup
      if Process.alive?(peer), do: GenServer.stop(peer)
      if Process.alive?(transport2), do: GenServer.stop(transport2)
    end

    test "handles connection failures gracefully", context do
      %{transport: transport, peer_id: peer_id} = context

      # Start peer with non-existent address
      {:ok, peer} = GenServer.start_link(Peer, [
        node_id: peer_id,
        transport: transport,
        address: {{127, 0, 0, 1}, 9999}  # Unlikely to be listening
      ])

      # Attempt connection
      :ok = Peer.connect(peer)

      # Should transition to :connecting state
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :connecting
      end)

      if Process.alive?(peer), do: GenServer.stop(peer)
    end

    test "disconnects cleanly", context do
      %{transport: transport1, peer_id: peer_id} = context

      # Start another transport for the remote peer
      test_id = System.unique_integer([:positive])
      transport2_name = String.to_atom("transport2_#{test_id}")
      {:ok, transport2} = GenServer.start_link(TcpTransport, [
        node_id: "remote_#{test_id}",
        name: transport2_name
      ], name: transport2_name)

      # Start listening on transport2
      {:ok, {addr, port}} = TcpTransport.listen(transport2_name, [])
      Process.sleep(@setup_delay)

      # Start and connect peer
      {:ok, peer} = GenServer.start_link(Peer, [
        node_id: peer_id,
        transport: transport1,
        address: {addr, port}
      ])

      :ok = Peer.connect(peer)

      # Wait for connection
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :connected
      end)

      # Disconnect
      :ok = Peer.disconnect(peer)

      # Verify disconnected state
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :disconnected
      end)

      # Cleanup
      if Process.alive?(peer), do: GenServer.stop(peer)
      if Process.alive?(transport2), do: GenServer.stop(transport2)
    end
  end

  describe "reconnection behavior" do
    test "attempts reconnection after connection loss", context do
      %{transport: transport1, peer_id: peer_id} = context

      # Start another transport for the remote peer
      test_id = System.unique_integer([:positive])
      transport2_name = String.to_atom("transport2_#{test_id}")
      {:ok, transport2} = GenServer.start_link(TcpTransport, [
        node_id: "remote_#{test_id}",
        name: transport2_name
      ], name: transport2_name)

      # Start listening on transport2
      {:ok, {addr, port}} = TcpTransport.listen(transport2_name, [])
      Process.sleep(@setup_delay)

      # Start and connect peer
      {:ok, peer} = GenServer.start_link(Peer, [
        node_id: peer_id,
        transport: transport1,
        address: {addr, port}
      ])

      :ok = Peer.connect(peer)

      # Wait for initial connection
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :connected
      end)

      # Simulate connection loss by stopping transport2
      GenServer.stop(transport2)

      # Should transition to connecting state
      assert wait_until(fn ->
        {:ok, status} = Peer.get_status(peer)
        status == :connecting
      end)

      # Cleanup
      if Process.alive?(peer), do: GenServer.stop(peer)
    end
  end

  # Helper Functions

  defp wait_until(func, timeout \\ @connection_timeout, interval \\ 50) do
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
