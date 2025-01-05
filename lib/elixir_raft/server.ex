defmodule ElixirRaft.Server do
  @moduledoc """
  Main Raft server implementation that coordinates:
  - Role management (Leader/Follower/Candidate)
  - Message handling and dispatch
  - State machine operations
  - Log replication
  - Election process
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{ServerState, LogEntry, NodeId, Term}
  alias ElixirRaft.Consensus.{
    MessageDispatcher,
    StateMachine,
    ReplicationTracker,
    ElectionManager
  }
  alias ElixirRaft.Storage.{LogStore, StateStore}
  alias ElixirRaft.RPC.Messages.{
    RequestVote,
    RequestVoteResponse,
    AppendEntries,
    AppendEntriesResponse
  }

  @type server_options :: [
    node_id: NodeId.t(),
    cluster_size: pos_integer(),
    data_dir: String.t()
  ]

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :cluster_size,
      :data_dir,
      :message_dispatcher,
      :state_machine,
      :replication_tracker,
      :election_manager,
      :log_store,
      :state_store
    ]
  end

  # Client API

  @spec start_link(server_options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec submit_command(GenServer.server(), term()) ::
    {:ok, term()} | {:error, term()}
  def submit_command(server, command) do
    GenServer.call(server, {:submit_command, command})
  end

  @spec get_current_leader(GenServer.server()) ::
    {:ok, NodeId.t() | nil} | {:error, term()}
  def get_current_leader(server) do
    GenServer.call(server, :get_current_leader)
  end

  @spec get_server_state(GenServer.server()) ::
    {:ok, map()} | {:error, term()}
  def get_server_state(server) do
    GenServer.call(server, :get_server_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, state} <- initialize_state(validated_opts),
         :ok <- initialize_components(state) do
      {:ok, state}
    else
      {:error, reason} = error ->
        Logger.error("Failed to initialize Raft server: #{inspect(reason)}")
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:submit_command, command}, from, state) do
    case handle_client_command(command, from, state) do
      {:reply, reply, new_state} -> {:reply, reply, new_state}
      {:forward, leader_id} ->
        {:reply, {:error, {:not_leader, leader_id}}, state}
    end
  end

  def handle_call(:get_current_leader, _from, state) do
    {:ok, leader} = ElectionManager.get_leader(state.election_manager)
    {:reply, {:ok, leader}, state}
  end

  def handle_call(:get_server_state, _from, state) do
    server_state = %{
      node_id: state.node_id,
      current_leader: get_current_leader_id(state),
      current_term: get_current_term(state),
      last_applied: get_last_applied_index(state),
      commit_index: get_commit_index(state)
    }
    {:reply, {:ok, server_state}, state}
  end

  @impl true
  def handle_info({:append_entries_request, message}, state) do
    handle_append_entries(message, state)
  end

  def handle_info({:append_entries_response, message}, state) do
    handle_append_entries_response(message, state)
  end

  def handle_info({:request_vote_request, message}, state) do
    handle_request_vote(message, state)
  end

  def handle_info({:request_vote_response, message}, state) do
    handle_request_vote_response(message, state)
  end

  def handle_info(:election_timeout, state) do
    handle_election_timeout(state)
  end

  # Private Functions

  defp validate_options(opts) do
    with {:ok, node_id} <- validate_node_id(opts),
         {:ok, cluster_size} <- validate_cluster_size(opts),
         {:ok, data_dir} <- validate_data_dir(opts) do
      {:ok, [
        node_id: node_id,
        cluster_size: cluster_size,
        data_dir: data_dir
      ]}
    end
  end

  defp validate_node_id(opts) do
    case Keyword.fetch(opts, :node_id) do
      {:ok, node_id} -> NodeId.validate(node_id)
      :error -> {:error, :missing_node_id}
    end
  end

  defp validate_cluster_size(opts) do
    case Keyword.fetch(opts, :cluster_size) do
      {:ok, size} when is_integer(size) and size > 0 -> {:ok, size}
      :error -> {:error, :missing_cluster_size}
      _ -> {:error, :invalid_cluster_size}
    end
  end

  defp validate_data_dir(opts) do
    case Keyword.fetch(opts, :data_dir) do
      {:ok, dir} when is_binary(dir) -> {:ok, dir}
      :error -> {:error, :missing_data_dir}
      _ -> {:error, :invalid_data_dir}
    end
  end

  defp initialize_state(opts) do
    {:ok, %State{
      node_id: opts[:node_id],
      cluster_size: opts[:cluster_size],
      data_dir: opts[:data_dir]
    }}
  end

  defp initialize_components(state) do
    with {:ok, state_store} <- start_state_store(state),
         {:ok, log_store} <- start_log_store(state),
         {:ok, state_machine} <- start_state_machine(state),
         {:ok, replication_tracker} <- start_replication_tracker(state),
         {:ok, election_manager} <- start_election_manager(state),
         {:ok, message_dispatcher} <- start_message_dispatcher(state) do

      new_state = %{state |
        state_store: state_store,
        log_store: log_store,
        state_machine: state_machine,
        replication_tracker: replication_tracker,
        election_manager: election_manager,
        message_dispatcher: message_dispatcher
      }
      {:ok, new_state}
    end
  end

  defp start_state_store(%{node_id: node_id, data_dir: data_dir}) do
    StateStore.start_link([
      node_id: node_id,
      data_dir: Path.join(data_dir, "state"),
      name: store_name(node_id, :state_store)
    ])
  end

  defp start_log_store(%{node_id: node_id, data_dir: data_dir}) do
    LogStore.start_link([
      node_id: node_id,
      data_dir: Path.join(data_dir, "log"),
      name: store_name(node_id, :log_store)
    ])
  end

  defp start_state_machine(%{node_id: node_id, data_dir: data_dir} = state) do
    StateMachine.start_link([
      node_id: node_id,
      log_store: state.log_store,
      snapshot_dir: Path.join(data_dir, "snapshots"),
      name: store_name(node_id, :state_machine)
    ])
  end

  defp start_replication_tracker(%{node_id: node_id, cluster_size: cluster_size} = state) do
    ReplicationTracker.start_link([
      node_id: node_id,
      cluster_size: cluster_size,
      current_term: get_current_term(state),
      last_log_index: get_last_log_index(state),
      name: store_name(node_id, :replication_tracker)
    ])
  end

  defp start_election_manager(%{node_id: node_id, cluster_size: cluster_size} = state) do
    ElectionManager.start_link([
      node_id: node_id,
      cluster_size: cluster_size,
      current_term: get_current_term(state),
      name: store_name(node_id, :election_manager)
    ])
  end

  defp start_message_dispatcher(%{node_id: node_id}) do
      MessageDispatcher.start_link([
        node_id: node_id,
        name: store_name(node_id, :message_dispatcher)
      ])
    end

  defp handle_client_command(command, from, %{election_manager: manager, node_id: my_node_id} = state) do
      case ElectionManager.get_leader(manager) do
        {:ok, leader_id} when leader_id == my_node_id ->
          handle_leader_command(command, from, state)
        {:ok, leader_id} when not is_nil(leader_id) ->
          {:forward, leader_id}
        _ ->
          {:reply, {:error, :no_leader}, state}
      end
    end

  defp handle_leader_command(command, _from, state) do
    entry = create_log_entry(command, state)

    case LogStore.append(state.log_store, entry) do
      {:ok, index} ->
        ReplicationTracker.reset_progress(state.replication_tracker, index)
        {:reply, {:ok, :accepted}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp create_log_entry(command, state) do
    {:ok, term} = ElectionManager.get_current_term(state.election_manager)
    {:ok, last_index} = LogStore.get_last_index(state.log_store)

    LogEntry.new!(
      last_index + 1,
      term,
      command
    )
  end

  defp handle_append_entries(message, state) do
    MessageDispatcher.dispatch_message(
      state.message_dispatcher,
      {:append_entries_request, message}
    )
    {:noreply, state}
  end

  defp handle_append_entries_response(message, state) do
    MessageDispatcher.dispatch_message(
      state.message_dispatcher,
      {:append_entries_response, message}
    )
    {:noreply, state}
  end

  defp handle_request_vote(message, state) do
    MessageDispatcher.dispatch_message(
      state.message_dispatcher,
      {:request_vote_request, message}
    )
    {:noreply, state}
  end

  defp handle_request_vote_response(message, state) do
    MessageDispatcher.dispatch_message(
      state.message_dispatcher,
      {:request_vote_response, message}
    )
    {:noreply, state}
  end

  defp handle_election_timeout(state) do
    ElectionManager.start_election(state.election_manager)
    {:noreply, state}
  end

  defp get_current_leader_id(state) do
    {:ok, leader} = ElectionManager.get_leader(state.election_manager)
    leader
  end

  defp get_current_term(state) do
    {:ok, term} = StateStore.get_current_term(state.state_store)
    term
  end

  defp get_last_applied_index(state) do
    {:ok, index} = StateMachine.get_last_applied_index(state.state_machine)
    index
  end

  defp get_commit_index(state) do
    {:ok, index} = ReplicationTracker.get_commit_index(state.replication_tracker)
    index
  end

  defp get_last_log_index(state) do
    {:ok, index} = LogStore.get_last_index(state.log_store)
    index
  end

  defp store_name(node_id, component) do
    :"#{component}_#{node_id}"
  end

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
