defmodule ElixirRaft.Consensus.CommitManager do
  @moduledoc """
  Manages the commit index and ensures log safety in the Raft consensus protocol.
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{Term, LogEntry, NodeId}
  alias ElixirRaft.Storage.LogStore

  @type index :: non_neg_integer()
  @type match_index :: %{NodeId.t() => index()}

  defmodule State do
    @moduledoc false

    @type index :: non_neg_integer()

    @type t :: %__MODULE__{
      node_id: NodeId.t(),
      log_store: GenServer.server(),
      commit_index: index(),
      last_applied: index(),
      pending_commits: [{index(), Term.t()}],
      apply_callback: (LogEntry.t() -> :ok | {:error, term()})
    }

    defstruct [
      :node_id,
      :log_store,
      :commit_index,
      :last_applied,
      :pending_commits,
      :apply_callback
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec get_commit_index(GenServer.server()) :: {:ok, index()} | {:error, term()}
  def get_commit_index(server) do
    GenServer.call(server, :get_commit_index)
  end

  @spec get_last_applied(GenServer.server()) :: {:ok, index()} | {:error, term()}
  def get_last_applied(server) do
    GenServer.call(server, :get_last_applied)
  end

  @spec update_commit_index(GenServer.server(), index(), Term.t()) ::
    :ok | {:error, term()}
  def update_commit_index(server, new_index, current_term) do
    GenServer.call(server, {:update_commit_index, new_index, current_term})
  end

  @spec advance_commit_index(GenServer.server(), match_index(), Term.t()) ::
    :ok | {:error, term()}
  def advance_commit_index(server, match_index, current_term) do
    GenServer.call(server, {:advance_commit_index, match_index, current_term})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, state} <- init_state(opts) do
      {:ok, state, {:continue, :apply_pending}}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize commit manager: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:apply_pending, state) do
    case apply_pending_entries(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("Failed to apply pending entries: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:get_commit_index, _from, state) do
    {:reply, {:ok, state.commit_index}, state}
  end

  def handle_call(:get_last_applied, _from, state) do
    {:reply, {:ok, state.last_applied}, state}
  end

  def handle_call({:update_commit_index, new_index, term}, _from, state) do
    with :ok <- validate_commit_index(new_index, term, state),
         {:ok, new_state} <- do_update_commit_index(new_index, state) do
      case apply_pending_entries(new_state) do
        {:ok, final_state} ->
          {:reply, :ok, final_state}
        {:error, :failed, partial_state} ->
          {:reply, {:error, :failed}, partial_state}
        {:error, reason} ->
          Logger.warning("Failed to update commit index: #{inspect(reason)}", [])
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} = error ->
        Logger.warning("Failed to update commit index: #{inspect(reason)}", [])
        {:reply, error, state}
    end
  end

  def handle_call({:advance_commit_index, match_index, term}, _from, state) do
    with {:ok, new_index} <- calculate_commit_index(match_index, term, state),
         {:ok, new_state} <- do_update_commit_index(new_index, state),
         {:ok, final_state} <- apply_pending_entries(new_state) do
      {:reply, :ok, final_state}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to advance commit index: #{inspect(reason)}", [])
        {:reply, error, state}
    end
  end

  # Private Functions

  defp init_state(opts) do
    with {:ok, node_id} <- validate_node_id(opts),
         log_store <- Keyword.fetch!(opts, :log_store),
         apply_callback <- Keyword.fetch!(opts, :apply_callback) do
      {:ok, %State{
        node_id: node_id,
        log_store: log_store,
        commit_index: 0,
        last_applied: 0,
        pending_commits: [],
        apply_callback: apply_callback
      }}
    end
  end

  defp validate_node_id(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    NodeId.validate(node_id)
  end

  defp validate_commit_index(new_index, term, state) do
    with {:ok, {last_index, _}} <- LogStore.get_last_entry_info(state.log_store),
         :ok <- validate_index_bounds(new_index, last_index),
         :ok <- validate_term(term) do
      :ok
    end
  end

  defp validate_index_bounds(new_index, last_index)
       when new_index >= 0 and new_index <= last_index do
    :ok
  end

  defp validate_index_bounds(_, _) do
    {:error, :invalid_commit_index}
  end

  defp validate_term(term) when is_integer(term) and term >= 0, do: :ok
  defp validate_term(_), do: {:error, :invalid_term}

  defp do_update_commit_index(new_index, state) when new_index > state.commit_index do
    with {:ok, entries} <- LogStore.get_entries(
      state.log_store,
      state.last_applied + 1,
      new_index
    ) do
      new_pending = Enum.map(entries, fn entry -> {entry.index, entry.term} end)
      {:ok, %{state |
        commit_index: new_index,
        pending_commits: state.pending_commits ++ new_pending
      }}
    end
  end

  defp do_update_commit_index(_, state), do: {:ok, state}

  defp calculate_commit_index(match_index, current_term, state) do
    match_indexes = Map.values(match_index)
    sorted_indexes = Enum.sort(match_indexes, :desc)

    majority_size = div(map_size(match_index) + 1, 2) + 1

    case find_majority_index(sorted_indexes, majority_size, state, current_term) do
      {:ok, index} when index > state.commit_index -> {:ok, index}
      _ -> {:ok, state.commit_index}
    end
  end

  defp find_majority_index(indexes, majority_size, state, current_term) do
    case Enum.find(indexes, fn index ->
      count_matching = Enum.count(indexes, &(&1 >= index)) + 1
      with true <- count_matching >= majority_size,
           {:ok, entry} <- LogStore.get_entry(state.log_store, index) do
        entry.term == current_term
      else
        _ -> false
      end
    end) do
      nil -> {:error, :no_majority}
      index -> {:ok, index}
    end
  end

  defp apply_pending_entries(state) do
    Enum.reduce_while(state.pending_commits, {:ok, state}, fn {index, _term}, {:ok, acc_state} ->
      case apply_single_entry(index, acc_state) do
        {:ok, new_state} ->
          {:cont, {:ok, new_state}}
        {:error, _} = _error ->
          {:halt, {:error, :failed, acc_state}}
      end
    end)
  end

  defp apply_single_entry(index, state) do
    with {:ok, entry} <- LogStore.get_entry(state.log_store, index) do
      case state.apply_callback.(entry) do
        :ok ->
          {:ok, %{state |
            last_applied: index,
            pending_commits: Enum.drop_while(
              state.pending_commits,
              fn {i, _} -> i <= index end
            )
          }}
        {:error, _} = error ->
          error
      end
    end
  end

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
