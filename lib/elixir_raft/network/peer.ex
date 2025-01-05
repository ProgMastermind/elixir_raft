defmodule ElixirRaft.Network.Peer do
  @moduledoc """
  Manages the state and connection to a single peer in the Raft cluster.
  Tracks:
  - Connection status
  - RPC message history
  - Heartbeat timing
  - Backoff/retry logic
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.NodeId
  alias ElixirRaft.Network.TcpTransport

  @reconnect_interval 1000
  @max_reconnect_interval 30_000

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,           # ID of the peer
      :transport,         # Transport process
      :address,          # {host, port}
      :status,           # :connected | :connecting | :disconnected
      :last_contact,     # Last successful communication timestamp
      :reconnect_timer,  # Timer reference for reconnection attempts
      :backoff_interval  # Current backoff interval
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec connect(GenServer.server()) :: :ok | {:error, term()}
  def connect(server) do
    GenServer.cast(server, :connect)
  end

  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server) do
    GenServer.cast(server, :disconnect)
  end

  @spec get_status(GenServer.server()) ::
    {:ok, :connected | :connecting | :disconnected} | {:error, term()}
  def get_status(server) do
    GenServer.call(server, :get_status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, transport} <- Keyword.fetch(opts, :transport),
         {:ok, address} <- Keyword.fetch(opts, :address) do
      state = %State{
        node_id: node_id,
        transport: transport,
        address: address,
        status: :disconnected,
        backoff_interval: @reconnect_interval
      }
      {:ok, state}
    else
      :error ->
        {:stop, {:shutdown, {:error, :missing_required_options}}}
    end
  end

  @impl true
  def handle_cast(:connect, %{status: :disconnected} = state) do
    case initiate_connection(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} ->
        new_state = schedule_reconnect(state)
        {:noreply, new_state}
    end
  end

  def handle_cast(:connect, state) do
    {:noreply, state}
  end

  def handle_cast(:disconnect, state) do
    new_state = do_disconnect(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_info(:try_reconnect, state) do
    case initiate_connection(state) do
      {:ok, new_state} ->
        {:noreply, new_state}
      {:error, _reason} ->
        new_state = schedule_reconnect(state)
        {:noreply, new_state}
    end
  end

  def handle_info({:connection_lost, reason}, state) do
    Logger.warn("Lost connection to peer #{state.node_id}: #{inspect(reason)}")
    new_state = handle_connection_loss(state)
    {:noreply, new_state}
  end

  # Private Functions

  defp initiate_connection(state) do
    case TcpTransport.connect(
      state.transport,
      state.node_id,
      state.address,
      []
    ) do
      {:ok, _socket} ->
        new_state = %{state |
          status: :connected,
          last_contact: System.monotonic_time(:millisecond),
          reconnect_timer: nil,
          backoff_interval: @reconnect_interval
        }
        {:ok, new_state}

      error ->
        Logger.debug("Failed to connect to peer #{state.node_id}: #{inspect(error)}")
        {:error, :connection_failed}
    end
  end

  defp do_disconnect(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

    if state.status == :connected do
      TcpTransport.close_connection(state.transport, state.node_id)
    end

    %{state |
      status: :disconnected,
      last_contact: nil,
      reconnect_timer: nil
    }
  end

  defp handle_connection_loss(state) do
    new_state = %{state |
      status: :disconnected,
      last_contact: nil
    }
    schedule_reconnect(new_state)
  end

  defp schedule_reconnect(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

    timer_ref = Process.send_after(
      self(),
      :try_reconnect,
      state.backoff_interval
    )

    %{state |
      status: :connecting,
      reconnect_timer: timer_ref,
      backoff_interval: min(
        state.backoff_interval * 2,
        @max_reconnect_interval
      )
    }
  end
end
