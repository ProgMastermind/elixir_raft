defmodule ElixirRaft.Consensus.MessageDispatcher do
  @moduledoc """
  Central coordinator for the Raft consensus protocol.
  Handles:
  - Message routing between nodes
  - Role-specific message handling
  - Role transitions
  - Network communication via TCP
  - State persistence
  - Broadcast coordination
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{ServerState, NodeId, Term}
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.Server.{Leader, Follower, Candidate}
  alias ElixirRaft.Network.TcpTransport
  alias ElixirRaft.Storage.{StateStore, LogStore}

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
      node_id: NodeId.t(),
      server_state: ServerState.t(),
      current_role: :follower | :candidate | :leader,
      role_state: term(),
      role_handler: module(),
      transport: GenServer.server(),
      state_store: GenServer.server(),
      log_store: GenServer.server(),
      peers: MapSet.t(NodeId.t()),
      pending_responses: %{reference() => {pid(), term()}},
      broadcast_queue: :queue.queue()
    }

    defstruct [
      :node_id,
      :server_state,
      :current_role,
      :role_state,
      :role_handler,
      :transport,
      :state_store,
      :log_store,
      peers: MapSet.new(),
      pending_responses: %{},
      broadcast_queue: :queue.new()
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  def submit_command(server, command) do
    GenServer.call(server, {:submit_command, command})
  end

  def get_current_role(server) do
    GenServer.call(server, :get_current_role)
  end

  def get_server_state(server) do
    GenServer.call(server, :get_server_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, state} <- init_state(opts),
         {:ok, transport} <- init_transport(state),
         {:ok, state_with_transport} <- {:ok, %{state | transport: transport}},
         :ok <- start_peer_connections(state_with_transport) do
      {:ok, state_with_transport}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize message dispatcher: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_current_role, _from, state) do
    {:reply, {:ok, state.current_role}, state}
  end

  def handle_call(:get_server_state, _from, state) do
    {:reply, {:ok, state.server_state}, state}
  end

  def handle_call({:submit_command, command}, from, state) do
    case state.role_handler.handle_client_command(command, state.server_state, state.role_state) do
      {:ok, new_server_state, new_role_state, messages} when is_list(messages) ->
        # Handle multiple messages to be broadcast (common for leader)
        new_state = broadcast_messages(messages, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        })
        {:reply, :ok, new_state}

      {:ok, new_server_state, new_role_state, message} ->
        # Handle single message to be sent
        new_state = broadcast_message(message, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        })
        {:reply, :ok, new_state}

      {:ok, new_server_state, new_role_state} ->
        # No messages to send
        {:reply, :ok, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        }}

      {:redirect, leader_id} ->
        {:reply, {:error, {:redirect, leader_id}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:received_message, from_node, message_binary}, state) do
    case Messages.decode(message_binary) do
      {:ok, message} ->
        handle_decoded_message(message, from_node, state)
      {:error, reason} ->
        Logger.error("Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, type}, state) do
    case state.role_handler.handle_timeout(type, state.server_state, state.role_state) do
      {:ok, new_server_state, new_role_state} ->
        {:noreply, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        }}

      {:ok, new_server_state, new_role_state, message} ->
        new_state = broadcast_message(message, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        })
        {:noreply, new_state}

      {:transition, new_role, new_server_state} ->
        case handle_role_transition(new_role, new_server_state, state) do
          {:ok, new_state} -> {:noreply, new_state}
          {:error, reason} ->
            Logger.error("Failed to handle timeout transition: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  def handle_info({:broadcast_complete, ref}, state) do
    # Remove completed broadcast from pending responses
    {:noreply, %{state | pending_responses: Map.delete(state.pending_responses, ref)}}
  end

  def handle_info({:broadcast_failed, ref, reason}, state) do
    Logger.error("Broadcast failed: #{inspect(reason)}")
    {:noreply, %{state | pending_responses: Map.delete(state.pending_responses, ref)}}
  end

  # Private Functions

  defp init_state(opts) do
    with {:ok, node_id} <- validate_node_id(opts),
         {:ok, state_store} <- validate_store(opts, :state_store),
         {:ok, log_store} <- validate_store(opts, :log_store),
         {:ok, server_state} <- initialize_server_state(node_id),
         {:ok, role_state} <- initialize_role_state(:follower, server_state),
         peers <- load_peer_configuration() do

      {:ok, %State{
        node_id: node_id,
        server_state: server_state,
        current_role: :follower,
        role_state: role_state,
        role_handler: Follower,
        state_store: state_store,
        log_store: log_store,
        peers: peers
      }}
    end
  end

  defp init_transport(state) do
    transport_opts = [
      node_id: state.node_id,
      name: Module.concat(__MODULE__, "Transport_#{state.node_id}"),
      message_handler: &handle_transport_message/3
    ]
    TcpTransport.start_link(transport_opts)
  end

  defp start_peer_connections(state) do
    Enum.each(state.peers, fn peer_id ->
      case get_peer_address(peer_id) do
        {:ok, address} -> TcpTransport.connect(state.transport, peer_id, address, [])
        _ -> :ok
      end
    end)
    :ok
  end

  defp handle_decoded_message(message, from_node, state) do
    case dispatch_message(message, from_node, state) do
      {:ok, new_state, response} when not is_nil(response) ->
        send_response(state.transport, from_node, response)
        {:noreply, new_state}

      {:ok, new_state} ->
        {:noreply, new_state}

      {:transition, new_role, new_server_state} ->
        case handle_role_transition(new_role, new_server_state, state) do
          {:ok, final_state} -> {:noreply, final_state}
          {:error, reason} ->
            Logger.error("Failed to handle message transition: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  defp send_response(transport, to_node, response) do
    case Messages.encode(response) do
      {:ok, encoded} ->
        TcpTransport.send(transport, to_node, encoded)
      {:error, reason} ->
        Logger.error("Failed to encode response: #{inspect(reason)}")
        {:error, reason}
    end
  end



  defp dispatch_message(message, from_node, state) do
    handler_function = get_message_handler(message)
    case apply(state.role_handler, handler_function, [message, state.server_state, state.role_state]) do
      {:ok, new_server_state, new_role_state} ->
        {:ok, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        }}

      {:ok, new_server_state, new_role_state, response} ->
        {:ok, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        }, response}

      {:transition, new_role, new_server_state} ->
        {:transition, new_role, new_server_state}
    end
  end

  defp handle_role_transition(new_role, server_state, state) do
    with {:ok, term_state} <- maybe_increment_term(new_role, server_state),
         :ok <- persist_term(term_state.current_term, state),
         {:ok, role_state} <- initialize_role_state(new_role, term_state) do

      Logger.info("Role transition",
        from: state.current_role,
        to: new_role,
        term: term_state.current_term
      )

      # Handle any initial messages from the new role (e.g., vote requests from candidate)
      case role_state do
        {role_state_data, message} ->
          new_state = %{state |
            current_role: new_role,
            role_handler: get_role_handler(new_role),
            role_state: role_state_data,
            server_state: term_state
          }
          broadcast_message(message, new_state)
          {:ok, new_state}

        role_state_data ->
          {:ok, %{state |
            current_role: new_role,
            role_handler: get_role_handler(new_role),
            role_state: role_state_data,
            server_state: term_state
          }}
      end
    end
  end

  defp broadcast_message({:broadcast, message}, state) do
    Enum.each(state.peers, fn peer_id ->
      send_message(state.transport, peer_id, message)
    end)
    state
  end

  defp broadcast_message({:broadcast_multiple, messages}, state) do
    Enum.each(messages, fn {peer_id, message} ->
      send_message(state.transport, peer_id, message)
    end)
    state
  end

  defp broadcast_message({:send, to_node, message}, state) do
    send_message(state.transport, to_node, message)
    state
  end

  defp broadcast_message(nil, state), do: state

  defp broadcast_messages(messages, state) do
    Enum.reduce(messages, state, &broadcast_message(&1, &2))
  end

  defp send_message(transport, to_node, message) do
    case Messages.encode(message) do
      {:ok, encoded} ->
        TcpTransport.send(transport, to_node, encoded)
      {:error, reason} ->
        Logger.error("Failed to encode message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_message_handler(%Messages.AppendEntries{}), do: :handle_append_entries
  defp get_message_handler(%Messages.AppendEntriesResponse{}), do: :handle_append_entries_response
  defp get_message_handler(%Messages.RequestVote{}), do: :handle_request_vote
  defp get_message_handler(%Messages.RequestVoteResponse{}), do: :handle_request_vote_response

  defp get_role_handler(:follower), do: Follower
  defp get_role_handler(:candidate), do: Candidate
  defp get_role_handler(:leader), do: Leader

  defp maybe_increment_term(:candidate, server_state) do
    {:ok, %{server_state | current_term: Term.increment(server_state.current_term)}}
  end
  defp maybe_increment_term(_role, server_state), do: {:ok, server_state}

  defp persist_term(term, state) do
    StateStore.save_term(state.state_store, term)
  end

  defp initialize_role_state(role, server_state) do
    role_handler = get_role_handler(role)
    role_handler.init(server_state)
  end

  defp validate_node_id(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, validated_id} <- NodeId.validate(node_id) do
      {:ok, validated_id}
    else
      :error -> {:error, :missing_node_id}
      error -> error
    end
  end

  defp validate_store(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, "Missing #{key}"}
    end
  end

  defp initialize_server_state(node_id) do
    {:ok, ServerState.new(node_id)}
  end

  defp load_peer_configuration do
    peers = Application.get_env(:elixir_raft, :peers, %{})
    MapSet.new(Map.keys(peers))
  end

  defp get_peer_address(peer_id) do
    peers = Application.get_env(:elixir_raft, :peers, %{})
    case Map.get(peers, peer_id) do
      nil -> {:error, :peer_not_found}
      address -> {:ok, address}
    end
  end

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end

  defp handle_transport_message(from_node, message_binary, dispatcher_pid) do
    GenServer.cast(dispatcher_pid, {:received_message, from_node, message_binary})
  end
end
