defmodule ElixirRaft.Consensus.MessageDispatcher do
  @moduledoc """
  Central message routing and handling component for the Raft consensus protocol.
  Coordinates message flow between network layer and role-specific handlers.

  Responsibilities:
  - Message routing to appropriate role handlers
  - Role transitions
  - Term management
  - State coordination
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{ServerState, NodeId, Term}
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.Server.{Leader, Follower, Candidate}
  alias ElixirRaft.Storage.{LogStore, StateStore}

  @type role_handler :: Leader | Follower | Candidate
  @type dispatch_result ::
    {:ok, ServerState.t()} |
    {:transition, atom(), ServerState.t()} |
    {:error, term()}

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,           # NodeId.t()
      :server_state,      # ServerState.t()
      :current_role,      # :follower | :candidate | :leader
      :role_state,        # Role-specific state
      :role_handler,      # Module handling current role
      :state_store,       # StateStore for persistence
      :log_store,         # LogStore for log entries
      :message_handlers   # Map of message type to handler functions
    ]

    @type t :: %__MODULE__{
      node_id: NodeId.t(),
      server_state: ServerState.t(),
      current_role: atom(),
      role_state: term(),
      role_handler: module(),
      state_store: GenServer.server(),
      log_store: GenServer.server(),
      message_handlers: map()
    }
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec dispatch_message(GenServer.server(), term()) ::
    {:ok, term()} | {:error, term()}
  def dispatch_message(server, message) do
    GenServer.call(server, {:dispatch, message})
  end

  @spec get_current_role(GenServer.server()) ::
    {:ok, atom()} | {:error, term()}
  def get_current_role(server) do
    GenServer.call(server, :get_current_role)
  end

  @spec transition_to(GenServer.server(), atom()) ::
    :ok | {:error, term()}
  def transition_to(server, new_role) do
    if new_role in [:follower, :candidate, :leader] do
      GenServer.call(server, {:transition_to, new_role})
    else
      {:error, :invalid_role}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, state} <- init_state(opts) do
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize message dispatcher: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:dispatch, message}, _from, state) do
      case handle_message(message, state) do
        {:ok, new_server_state, new_role_state, response} ->
          new_state = %{state |
            server_state: new_server_state,
            role_state: new_role_state
          }
          {:reply, {:ok, response}, new_state}

        {:ok, new_server_state, new_role_state} ->  # Add this clause
          new_state = %{state |
            server_state: new_server_state,
            role_state: new_role_state
          }
          {:reply, :ok, new_state}

        {:transition, new_role, new_server_state, _role_state} ->
          case handle_transition(new_role, new_server_state, state) do
            {:ok, updated_state} ->
              # Re-handle message after transition
              case handle_message(message, updated_state) do
                {:ok, final_server_state, final_role_state, response} ->
                  final_state = %{updated_state |
                    server_state: final_server_state,
                    role_state: final_role_state
                  }
                  {:reply, {:ok, response}, final_state}
                {:ok, final_server_state, final_role_state} ->  # Add this clause
                  final_state = %{updated_state |
                    server_state: final_server_state,
                    role_state: final_role_state
                  }
                  {:reply, :ok, final_state}
                _ ->
                  {:reply, {:ok, nil}, updated_state}
              end
            {:error, reason} ->
              Logger.error("Transition failed: #{inspect(reason)}")
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          Logger.error("Message handling failed: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end

  def handle_call(:get_current_role, _from, state) do
    {:reply, {:ok, state.current_role}, state}
  end

  def handle_call({:transition_to, new_role}, _from, state) do
    case handle_transition(new_role, state.server_state, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:timeout, type} = _msg, state) when type in [:election, :heartbeat] do
    case state.role_handler.handle_timeout(type, state.server_state, state.role_state) do
      {:ok, new_server_state, new_role_state} ->
        {:noreply, %{state |
          server_state: new_server_state,
          role_state: new_role_state
        }}

      {:transition, new_role, new_server_state, _role_state} ->
        case handle_transition(new_role, new_server_state, state) do
          {:ok, updated_state} -> {:noreply, updated_state}
          {:error, reason} ->
            Logger.error("Transition failed: #{inspect(reason)}")
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Timeout handling failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("Unexpected message received: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  @spec init_state(keyword()) :: {:ok, State.t()} | {:error, term()}
  defp init_state(opts) do
    with {:ok, node_id} <- validate_node_id(opts),
         {:ok, state_store} <- validate_state_store(opts),
         {:ok, log_store} <- validate_log_store(opts),
         {:ok, server_state} <- initialize_server_state(node_id),
         {:ok, role_state} <- initialize_role_state(:follower, server_state) do

      state = %State{
        node_id: node_id,
        server_state: server_state,
        current_role: :follower,
        role_state: role_state,
        role_handler: Follower,
        state_store: state_store,
        log_store: log_store,
        message_handlers: initialize_message_handlers()
      }
      {:ok, state}
    end
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

  defp validate_state_store(opts) do
    case Keyword.fetch(opts, :state_store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_state_store}
    end
  end

  defp validate_log_store(opts) do
    case Keyword.fetch(opts, :log_store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_log_store}
    end
  end

  defp initialize_server_state(node_id) do
    {:ok, ServerState.new(node_id)}
  end

  defp initialize_role_state(role, server_state) do
    role_handler = get_role_handler(role)
    role_handler.init(server_state)
  end

  defp initialize_message_handlers do
    %{
      append_entries: &handle_append_entries/2,
      append_entries_response: &handle_append_entries_response/2,
      request_vote: &handle_request_vote/2,
      request_vote_response: &handle_request_vote_response/2
    }
  end

  defp handle_message(message, state) do
    case identify_message_type(message) do
      {:ok, type} ->
        handler = Map.get(state.message_handlers, type)
        handler.(message, state)
      {:error, _} = error -> error
    end
  end

  defp identify_message_type(message) do
    cond do
      match?(%Messages.AppendEntries{}, message) ->
        {:ok, :append_entries}
      match?(%Messages.AppendEntriesResponse{}, message) ->
        {:ok, :append_entries_response}
      match?(%Messages.RequestVote{}, message) ->
        {:ok, :request_vote}
      match?(%Messages.RequestVoteResponse{}, message) ->
        {:ok, :request_vote_response}
      true ->
        {:error, :unknown_message_type}
    end
  end

  defp handle_append_entries(message, state) do
    state.role_handler.handle_append_entries(
      message,
      state.server_state,
      state.role_state
    )
  end

  defp handle_append_entries_response(message, state) do
    state.role_handler.handle_append_entries_response(
      message,
      state.server_state,
      state.role_state
    )
  end

  defp handle_request_vote(message, state) do
    state.role_handler.handle_request_vote(
      message,
      state.server_state,
      state.role_state
    )
  end

  defp handle_request_vote_response(message, state) do
    state.role_handler.handle_request_vote_response(
      message,
      state.server_state,
      state.role_state
    )
  end

  defp handle_transition(new_role, server_state, state) do
    with {:ok, term_state} <- maybe_increment_term(new_role, server_state, state),
         :ok <- persist_term(term_state.current_term, state),
         {:ok, new_role_state} <- initialize_role_state(new_role, term_state) do
      new_state = %{state |
        current_role: new_role,
        role_handler: get_role_handler(new_role),
        role_state: new_role_state,
        server_state: term_state
      }
      {:ok, new_state}
    end
  end

  defp maybe_increment_term(:candidate, server_state, _state) do
    new_term = Term.increment(server_state.current_term)
    {:ok, %{server_state | current_term: new_term}}
  end
  defp maybe_increment_term(_role, server_state, _state), do: {:ok, server_state}

  defp persist_term(term, state) do
    StateStore.save_term(state.state_store, term)
  end

  defp get_role_handler(:follower), do: Follower
  defp get_role_handler(:candidate), do: Candidate
  defp get_role_handler(:leader), do: Leader

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
