defmodule ElixirRaft.Network.TcpTransport do
  use GenServer
  require Logger

  @behaviour ElixirRaft.Network.TransportBehaviour

  @max_message_size 1_048_576  # 1MB
  @frame_header_size 4
  @connection_timeout 5000
  @handshake_timeout 1000

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :listen_socket,
      :address,
      :port,
      :message_handler,
      :name,
      :acceptor_pid,
      connections: %{},           # NodeId -> {socket, metadata}
    ]
  end

  # Client API

  @impl ElixirRaft.Network.TransportBehaviour
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def listen(server, opts) do
    GenServer.call(server, {:listen, opts})
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def connect(server, node_id, {address, port}, _opts) do
    GenServer.call(server, {:connect, node_id, address, port}, @connection_timeout)
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def send(server, node_id, message) do
    case validate_message_size(message) do
      :ok -> GenServer.call(server, {:send, node_id, message})
      error -> error
    end
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def close_connection(server, node_id) do
    GenServer.cast(server, {:close_connection, node_id})
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def stop(server) do
    GenServer.stop(server)
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def register_message_handler(server, handler) when is_function(handler, 2) do
    GenServer.call(server, {:register_handler, handler})
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def connection_status(server, node_id) do
    GenServer.call(server, {:connection_status, node_id})
  end

  @impl ElixirRaft.Network.TransportBehaviour
  def get_local_address(server) do
    GenServer.call(server, :get_local_address)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %State{
      node_id: Keyword.get(opts, :node_id),
      name: Keyword.get(opts, :name, __MODULE__)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:listen, opts}, _from, state) do
    case :gen_tcp.listen(
      Keyword.get(opts, :port, 0),
      [:binary, active: true, reuseaddr: true, packet: @frame_header_size]
    ) do
      {:ok, socket} ->
        {:ok, {addr, port}} = :inet.sockname(socket)
        acceptor_pid = start_acceptor(socket, self())
        new_state = %{state |
          listen_socket: socket,
          address: addr,
          port: port,
          acceptor_pid: acceptor_pid
        }
        Logger.info("TCP Transport listening on port #{port}")
        {:reply, {:ok, {addr, port}}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to listen: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:connect, node_id, address, port}, _from, state) do
    Logger.debug("Attempting to connect to #{node_id} at #{inspect(address)}:#{port}")
    case establish_connection(node_id, address, port, state) do
      {:ok, socket, new_state} ->
        Logger.info("Successfully established bi-directional connection to #{node_id}")
        {:reply, {:ok, socket}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to establish connection to #{node_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:send, node_id, message}, _from, state) do
    case get_connection(node_id, state) do
      {:ok, socket} ->
        case send_message(socket, message) do
          :ok ->
            Logger.debug("Successfully sent message to #{node_id}")
            {:reply, :ok, state}
          error ->
            Logger.error("Failed to send message to #{node_id}: #{inspect(error)}")
            new_state = handle_send_error(node_id, socket, state)
            {:reply, error, new_state}
        end

      {:error, :not_connected} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:register_handler, handler}, _from, state) do
    {:reply, :ok, %{state | message_handler: handler}}
  end

  def handle_call({:connection_status, node_id}, _from, state) do
    status = case Map.get(state.connections, node_id) do
      {socket, _meta} when is_port(socket) -> :connected
      _ -> :disconnected
    end
    {:reply, status, state}
  end

  def handle_call(:get_local_address, _from, state) do
    case {state.address, state.port} do
      {nil, nil} -> {:reply, {:error, :not_listening}, state}
      {addr, port} -> {:reply, {:ok, {addr, port}}, state}
    end
  end

  def handle_call(:get_node_id, _from, state) do
    {:reply, {:ok, state.node_id}, state}
  end

  @impl true
  def handle_cast({:close_connection, node_id}, state) do
    new_state = case Map.get(state.connections, node_id) do
      {socket, _meta} ->
        Logger.info("Closing connection to #{node_id}")
        :gen_tcp.close(socket)
        remove_connection(node_id, state)
      nil ->
        state
    end
    {:noreply, new_state}
  end

  def handle_cast({:inbound_connection, socket, remote_node_id}, state) do
    Logger.info("Processing inbound connection from #{remote_node_id}")
    new_state = register_connection(remote_node_id, socket, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    case handle_received_data(socket, data, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("Error handling received data: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    Logger.info("TCP connection closed")
    new_state = handle_socket_closed(socket, state)
    {:noreply, new_state}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("TCP error: #{inspect(reason)}")
    new_state = handle_socket_closed(socket, state)
    {:noreply, new_state}
  end

  def handle_info({:EXIT, pid, reason}, %{acceptor_pid: pid} = state) do
    Logger.warn("Acceptor process exited: #{inspect(reason)}")
    new_acceptor_pid = case state.listen_socket do
      nil -> nil
      socket when is_port(socket) -> start_acceptor(socket, self())
    end
    {:noreply, %{state | acceptor_pid: new_acceptor_pid}}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message received: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp establish_connection(node_id, address, port, state) do
    connect_opts = [
      active: true,
      packet: @frame_header_size,
      send_timeout: @connection_timeout
    ]

    with {:ok, socket} <- :gen_tcp.connect(address, port, connect_opts),
         :ok <- perform_handshake(socket, state.node_id, node_id),
         new_state <- register_connection(node_id, socket, state) do
      {:ok, socket, new_state}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_handshake(socket, our_node_id, their_node_id) do
    # Send our node_id
    with :ok <- send_message(socket, encode_handshake(our_node_id)),
         # Receive and verify their node_id
         {:ok, received_data} <- receive_handshake(socket),
         ^their_node_id <- decode_handshake(received_data) do
      :ok
    else
      error ->
        :gen_tcp.close(socket)
        {:error, {:handshake_failed, error}}
    end
  end

  defp receive_handshake(socket) do
    receive do
      {:tcp, ^socket, data} -> {:ok, data}
      {:tcp_closed, ^socket} -> {:error, :closed}
      {:tcp_error, ^socket, reason} -> {:error, reason}
    after
      @handshake_timeout -> {:error, :handshake_timeout}
    end
  end

  defp register_connection(node_id, socket, state) do
    metadata = %{
      established: true,
      created_at: System.system_time(:second)
    }
    %{state | connections: Map.put(state.connections, node_id, {socket, metadata})}
  end

  defp start_acceptor(socket, parent) do
    spawn_link(fn -> acceptor_loop(socket, parent) end)
  end

  defp acceptor_loop(socket, parent) do
    case :gen_tcp.accept(socket) do
      {:ok, client_socket} ->
        handle_new_connection(client_socket, parent)
        acceptor_loop(socket, parent)

      {:error, :closed} ->
        Logger.info("Listen socket closed, stopping acceptor loop")
        :ok

      {:error, reason} ->
        Logger.error("Accept failed: #{inspect(reason)}")
        Process.sleep(100)
        acceptor_loop(socket, parent)
    end
  end

  defp handle_new_connection(socket, parent) do
    :ok = :inet.setopts(socket, [active: true])
    case receive_handshake(socket) do
      {:ok, data} ->
        remote_node_id = decode_handshake(data)
        {:ok, our_node_id} = GenServer.call(parent, :get_node_id)

        case send_message(socket, encode_handshake(our_node_id)) do
          :ok ->
          :gen_tcp.controlling_process(socket, parent) # <-- try adding this
            GenServer.cast(parent, {:inbound_connection, socket, remote_node_id})
            {:ok, remote_node_id}
          error ->
            Logger.error("Failed to complete handshake: #{inspect(error)}")
            :gen_tcp.close(socket)
            error
        end

      {:error, reason} ->
        Logger.error("Failed to receive handshake: #{inspect(reason)}")
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp validate_message_size(message) when byte_size(message) <= @max_message_size, do: :ok
  defp validate_message_size(_), do: {:error, :message_too_large}

  defp send_message(socket, data) do
    try do
      :gen_tcp.send(socket, data)
    catch
      :error, :closed -> {:error, :closed}
    end
  end

  defp handle_received_data(socket, data, state) do
    case get_node_id_for_socket(socket, state) do
      {:ok, node_id} ->
        if state.message_handler do
          binary_data = if is_list(data), do: IO.iodata_to_binary(data), else: data
          state.message_handler.(node_id, binary_data)
          {:ok, state}
        else
          {:error, :no_message_handler}
        end
      {:error, reason} = error ->
        Logger.error("Failed to handle received data: #{inspect(reason)}")
        error
    end
  end

  defp get_node_id_for_socket(socket, state) do
    Enum.find_value(state.connections, {:error, :unknown_connection}, fn {node_id, {conn_socket, _}} ->
      if conn_socket == socket, do: {:ok, node_id}
    end)
  end

  defp handle_socket_closed(socket, state) do
    case get_node_id_for_socket(socket, state) do
      {:ok, node_id} -> remove_connection(node_id, state)
      {:error, _} -> state
    end
  end

  defp handle_send_error(node_id, _socket, state) do
    remove_connection(node_id, state)
  end

  defp remove_connection(node_id, state) do
    %{state | connections: Map.delete(state.connections, node_id)}
  end

  defp get_connection(node_id, state) do
    case Map.get(state.connections, node_id) do
      {socket, _metadata} -> {:ok, socket}
      nil -> {:error, :not_connected}
    end
  end

  defp encode_handshake(node_id) do
    :erlang.term_to_binary({:handshake, node_id})
  end

  defp decode_handshake(data) when is_list(data) do
    decode_handshake(IO.iodata_to_binary(data))
  end
  defp decode_handshake(data) when is_binary(data) do
    case :erlang.binary_to_term(data) do
      {:handshake, node_id} -> node_id
      _ -> raise "Invalid handshake data"
    end
  end
end
