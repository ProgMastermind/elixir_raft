defmodule ElixirRaft.MessageDispatcher do
  @moduledoc """
  Handles sending and receiving messages between Raft nodes.
  Responsibilities:
  - Message routing between nodes
  - Connection management
  - Message serialization/deserialization
  - Retry logic for failed sends
  - Queue management for disconnected peers
  """

  use GenServer
  require Logger

  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.Core.{NodeId, ClusterInfo}
  alias ElixirRaft.RPC.Messages

  defmodule State do
    @type t :: %__MODULE__{
      node_id: NodeId.t(),
      transport: GenServer.server(),
      server: pid(),
      server_name: atom(),
      pending_messages: %{NodeId.t() => [{reference(), term()}]},
      retry_timers: %{reference() => reference()},
      connection_status: %{NodeId.t() => :connected | :disconnected},
      retry_count: %{reference() => non_neg_integer()}
    }

    defstruct [
      :node_id,
      :transport,
      :server,
      :server_name,
      pending_messages: %{},
      retry_timers: %{},
      connection_status: %{},
      retry_count: %{}
    ]
  end

  @retry_interval 1000
  @max_retries 3

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def broadcast(server, message) do
    GenServer.cast(server, {:broadcast, message})
  end

  def send_message(server, to_node_id, message) do
    GenServer.cast(server, {:send, to_node_id, message})
  end

  def broadcast_multiple(server, messages) when is_list(messages) do
    GenServer.cast(server, {:broadcast_multiple, messages})
  end

  def get_connection_status(server, node_id) do
    GenServer.call(server, {:get_connection_status, node_id})
  end

  def connect_peer(server, {node_id, address}) do
    GenServer.cast(server, {:connect_peer, node_id, address})
  end

  def disconnect_peer(server, node_id) do
    GenServer.cast(server, {:disconnect_peer, node_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, state} <- init_state(opts),
         :ok <- setup_transport_handler(state) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:broadcast, message}, state) do
    peers = ClusterInfo.get_peer_ids(state.node_id)
    encoded_msg = Messages.encode(message)

    Enum.each(peers, fn peer_id ->
      do_send_message(peer_id, encoded_msg, state)
    end)

    {:noreply, state}
  end

  def handle_cast({:send, to_node_id, message}, state) do
    encoded_msg = Messages.encode(message)
    new_state = do_send_message(to_node_id, encoded_msg, state)
    {:noreply, new_state}
  end

  def handle_cast({:broadcast_multiple, messages}, state) do
    new_state = Enum.reduce(messages, state, fn {peer_id, message}, acc_state ->
      encoded_msg = Messages.encode(message)
      do_send_message(peer_id, encoded_msg, acc_state)
    end)

    {:noreply, new_state}
  end

  def handle_cast({:connect_peer, node_id, address}, state) do
    case TcpTransport.connect(state.transport, node_id, address, []) do
      {:ok, _} ->
        new_state = %{state |
          connection_status: Map.put(state.connection_status, node_id, :connected)
        }
        retry_pending_messages(node_id, new_state)
        {:noreply, new_state}
      {:error, reason} ->
        Logger.warn("Failed to connect to peer #{node_id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:disconnect_peer, node_id}, state) do
    TcpTransport.close_connection(state.transport, node_id)
    new_state = %{state |
      connection_status: Map.put(state.connection_status, node_id, :disconnected)
    }
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_connection_status, node_id}, _from, state) do
    status = Map.get(state.connection_status, node_id, :disconnected)
    {:reply, status, state}
  end

  @impl true
  def handle_info({:retry_message, ref}, state) do
    case find_pending_message(ref, state) do
      {node_id, message} ->
        new_state = handle_retry(node_id, message, ref, state)
        {:noreply, new_state}
      nil ->
        {:noreply, cleanup_retry_timer(ref, state)}
    end
  end

  def handle_info({:connection_status_changed, node_id, status}, state) do
    new_state = %{state |
      connection_status: Map.put(state.connection_status, node_id, status)
    }

    case status do
      :connected -> retry_pending_messages(node_id, new_state)
      :disconnected -> queue_pending_messages(node_id, new_state)
    end

    {:noreply, new_state}
  end

  # Private Functions

  defp init_state(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, transport} <- Keyword.fetch(opts, :transport),
         {:ok, server} <- Keyword.fetch(opts, :server),
         {:ok, server_name} <- Keyword.fetch(opts, :server_name) do
      state = %State{
        node_id: node_id,
        transport: transport,
        server: server,
        server_name: server_name
      }
      {:ok, state}
    else
      :error -> {:error, :missing_required_options}
    end
  end

  defp setup_transport_handler(state) do
    TcpTransport.register_message_handler(state.transport, &handle_network_message/2)
    :ok
  end

  defp do_send_message(to_node_id, encoded_msg, state) do
    case TcpTransport.send(state.transport, to_node_id, encoded_msg) do
      :ok -> state
      {:error, _reason} -> queue_message(to_node_id, encoded_msg, state)
    end
  end

  defp queue_message(node_id, message, state) do
    ref = make_ref()
    timer_ref = schedule_retry(ref)

    new_pending = Map.update(
      state.pending_messages,
      node_id,
      [{ref, message}],
      &[{ref, message} | &1]
    )

    %{state |
      pending_messages: new_pending,
      retry_timers: Map.put(state.retry_timers, ref, timer_ref),
      retry_count: Map.put(state.retry_count, ref, 0)
    }
  end

  defp handle_retry(node_id, message, ref, state) do
    retry_count = Map.get(state.retry_count, ref, 0)

    if retry_count < @max_retries do
      case TcpTransport.send(state.transport, node_id, message) do
        :ok -> cleanup_retry_state(ref, node_id, state)
        {:error, _} -> schedule_next_retry(node_id, message, ref, retry_count + 1, state)
      end
    else
      Logger.warn("Max retries reached for message to #{node_id}")
      cleanup_retry_state(ref, node_id, state)
    end
  end

  defp schedule_retry(ref) do
    Process.send_after(self(), {:retry_message, ref}, @retry_interval)
  end

  defp schedule_next_retry(node_id, message, ref, retry_count, state) do
    timer_ref = schedule_retry(ref)

    %{state |
      retry_timers: Map.put(state.retry_timers, ref, timer_ref),
      retry_count: Map.put(state.retry_count, ref, retry_count)
    }
  end

  defp cleanup_retry_state(ref, node_id, state) do
    %{state |
      pending_messages: remove_pending_message(node_id, ref, state.pending_messages),
      retry_timers: Map.delete(state.retry_timers, ref),
      retry_count: Map.delete(state.retry_count, ref)
    }
  end

  defp cleanup_retry_timer(ref, state) do
    %{state | retry_timers: Map.delete(state.retry_timers, ref)}
  end

  defp find_pending_message(ref, state) do
    Enum.find_value(state.pending_messages, fn {node_id, messages} ->
      case Enum.find(messages, fn {msg_ref, _} -> msg_ref == ref end) do
        {^ref, message} -> {node_id, message}
        nil -> nil
      end
    end)
  end

  defp remove_pending_message(node_id, ref, pending_messages) do
    case Map.get(pending_messages, node_id) do
      nil ->
        pending_messages
      messages ->
        new_messages = Enum.reject(messages, fn {msg_ref, _} -> msg_ref == ref end)
        if Enum.empty?(new_messages) do
          Map.delete(pending_messages, node_id)
        else
          Map.put(pending_messages, node_id, new_messages)
        end
    end
  end

  defp retry_pending_messages(node_id, state) do
    case Map.get(state.pending_messages, node_id) do
      nil ->
        state
      messages ->
        Enum.reduce(messages, state, fn {ref, message}, acc_state ->
          case TcpTransport.send(state.transport, node_id, message) do
            :ok -> cleanup_retry_state(ref, node_id, acc_state)
            {:error, _} -> acc_state
          end
        end)
    end
  end

  defp queue_pending_messages(node_id, state) do
    state
  end

  defp handle_network_message(from_node_id, message_binary) do
    case Messages.decode(message_binary) do
      {:ok, decoded_msg} ->
        GenServer.cast(self(), {:forward_to_server, from_node_id, decoded_msg})
      {:error, reason} ->
        Logger.error("Failed to decode message from #{from_node_id}: #{inspect(reason)}")
    end
  end
end
