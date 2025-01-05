defmodule ElixirRaft.Consensus.ReplicationTracker do
  @moduledoc """
  Tracks log replication status across the Raft cluster.
  Manages:
  - Match index for each follower
  - Next index tracking
  - Quorum calculations
  - Commitment decisions
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{Term, NodeId}

  @type progress_info :: %{
    match_index: non_neg_integer(),
    next_index: pos_integer(),
    last_response: integer() | nil  # timestamp of last response
  }

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,           # Current node's ID (NodeId.t())
      :cluster_size,      # Total number of nodes in cluster
      :current_term,      # Current term
      :last_log_index,    # Index of last log entry
      :commit_index,      # Highest log entry known to be committed
      :cluster_nodes,     # List of all node IDs in the cluster
      progress: %{},      # Map of NodeId.t() to progress_info
      quorum_size: 0      # Number of nodes needed for quorum
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec update_term(GenServer.server(), Term.t()) :: :ok | {:error, term()}
  def update_term(server, term) do
    GenServer.call(server, {:update_term, term})
  end

  @spec record_response(GenServer.server(), NodeId.t(), non_neg_integer(), boolean()) ::
    {:ok, :committed | :not_committed} | {:error, term()}
  def record_response(server, node_id, match_index, success) do
    case NodeId.validate(node_id) do
      {:ok, valid_node_id} ->
        GenServer.call(server, {:record_response, valid_node_id, match_index, success})
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_next_index(GenServer.server(), NodeId.t()) :: {:ok, pos_integer()} | {:error, term()}
  def get_next_index(server, node_id) do
    case NodeId.validate(node_id) do
      {:ok, valid_node_id} ->
        GenServer.call(server, {:get_next_index, valid_node_id})
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_commit_index(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_commit_index(server) do
    GenServer.call(server, :get_commit_index)
  end

  @spec reset_progress(GenServer.server(), non_neg_integer()) :: :ok | {:error, term()}
  def reset_progress(server, last_log_index) do
    GenServer.call(server, {:reset_progress, last_log_index})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, validated_node_id} <- NodeId.validate(node_id),
         {:ok, cluster_size} <- Keyword.fetch(opts, :cluster_size),
         {:ok, current_term} <- Keyword.fetch(opts, :current_term),
         {:ok, last_log_index} <- Keyword.fetch(opts, :last_log_index) do

      # Get cluster nodes from options or generate them
      cluster_nodes = Keyword.get(opts, :cluster_nodes) || generate_cluster_nodes(cluster_size)

      state = %State{
        node_id: validated_node_id,
        cluster_size: cluster_size,
        current_term: current_term,
        last_log_index: last_log_index,
        commit_index: 0,
        cluster_nodes: cluster_nodes,
        quorum_size: div(cluster_size, 2) + 1
      }

      {:ok, initialize_progress(state)}
    else
      {:error, reason} -> {:stop, reason}
      :error -> {:stop, :missing_required_options}
    end
  end

  @impl true
  def handle_call({:update_term, new_term}, _from, state) do
    if new_term >= state.current_term do
      {:reply, :ok, %{state | current_term: new_term}}
    else
      {:reply, {:error, :stale_term}, state}
    end
  end

  def handle_call({:record_response, node_id, match_index, true}, _from, state) do
    case update_progress(state, node_id, match_index) do
      {:ok, new_state, commit_status} -> {:reply, {:ok, commit_status}, new_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:record_response, node_id, _match_index, false}, _from, state) do
    case decrement_next_index(state, node_id) do
      {:ok, new_state} -> {:reply, {:ok, :not_committed}, new_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_next_index, node_id}, _from, state) do
    case Map.get(state.progress, node_id) do
      %{next_index: next_index} -> {:reply, {:ok, next_index}, state}
      nil -> {:reply, {:error, :unknown_node}, state}
    end
  end

  def handle_call(:get_commit_index, _from, state) do
    {:reply, {:ok, state.commit_index}, state}
  end

  def handle_call({:reset_progress, last_log_index}, _from, state) do
    new_state = %{state |
      last_log_index: last_log_index,
      progress: initialize_progress_map(state.cluster_nodes, last_log_index + 1)
    }
    {:reply, :ok, new_state}
  end

  # Private Functions

  defp initialize_progress(%State{} = state) do
    progress = initialize_progress_map(state.cluster_nodes, state.last_log_index + 1)
    %{state | progress: progress}
  end

  defp initialize_progress_map(cluster_nodes, next_index) do
    cluster_nodes
    |> Enum.map(fn node_id -> {node_id, initial_progress(next_index)} end)
    |> Map.new()
  end

  defp initial_progress(next_index) do
    %{
      match_index: 0,
      next_index: next_index,
      last_response: nil
    }
  end

  defp generate_cluster_nodes(cluster_size) do
    Enum.map(1..cluster_size, fn _id -> NodeId.generate() end)
  end

  defp update_progress(state, node_id, match_index) do
    with {:ok, progress} <- validate_progress(state, node_id, match_index) do
      new_progress = Map.put(state.progress, node_id, %{
        progress |
        match_index: match_index,
        next_index: match_index + 1,
        last_response: System.monotonic_time(:millisecond)
      })

      new_state = %{state | progress: new_progress}

      case check_commitment(new_state, match_index) do
        {:ok, :committed, final_state} -> {:ok, final_state, :committed}
        {:ok, :not_committed, final_state} -> {:ok, final_state, :not_committed}
      end
    end
  end

  defp validate_progress(state, node_id, match_index) do
    with {:ok, progress} <- Map.fetch(state.progress, node_id),
         true <- match_index <= state.last_log_index do
      {:ok, progress}
    else
      :error -> {:error, :unknown_node}
      false -> {:error, :invalid_match_index}
    end
  end

  defp check_commitment(state, match_index) do
    if match_index > state.commit_index do
      matching_nodes = count_matching_nodes(state.progress, match_index)

      if matching_nodes >= state.quorum_size do
        {:ok, :committed, %{state | commit_index: match_index}}
      else
        {:ok, :not_committed, state}
      end
    else
      {:ok, :not_committed, state}
    end
  end

  defp count_matching_nodes(progress, match_index) do
    Enum.count(progress, fn {_node_id, info} ->
      info.match_index >= match_index
    end)
  end

  defp decrement_next_index(state, node_id) do
    case Map.get(state.progress, node_id) do
      nil ->
        {:error, :unknown_node}
      progress ->
        new_next_index = max(1, progress.next_index - 1)
        new_progress = %{progress | next_index: new_next_index}
        {:ok, %{state | progress: Map.put(state.progress, node_id, new_progress)}}
    end
  end

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
