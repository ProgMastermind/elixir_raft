defmodule ElixirRaft.Consensus.StateMachine do
  @moduledoc """
  Manages application state in the Raft cluster.
  Responsible for:
  - Applying committed log entries
  - State management and persistence
  - Snapshot creation and restoration
  - State queries and updates
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.LogEntry
  alias ElixirRaft.Storage.LogStore

  @type command :: {:set, term(), term()} |
                  {:delete, term()} |
                  {:get, term()}
  @type state_data :: %{optional(term()) => term()}
  @type snapshot :: {non_neg_integer(), state_data()}

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :log_store,
      :snapshot_dir,
      :last_applied_index,
      :last_snapshot_index,
      :last_snapshot_term,
      data: %{},            # Current state data
      pending_reads: []     # Queued read operations
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec apply_entries(GenServer.server(), [LogEntry.t()], non_neg_integer()) ::
    {:ok, non_neg_integer()} | {:error, term()}
  def apply_entries(server, entries, commit_index) do
    GenServer.call(server, {:apply_entries, entries, commit_index})
  end

  @spec get_state(GenServer.server()) :: {:ok, state_data()} | {:error, term()}
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec create_snapshot(GenServer.server()) ::
    {:ok, snapshot()} | {:error, term()}
  def create_snapshot(server) do
    GenServer.call(server, :create_snapshot)
  end

  @spec restore_snapshot(GenServer.server(), snapshot()) ::
    :ok | {:error, term()}
  def restore_snapshot(server, snapshot) do
    GenServer.call(server, {:restore_snapshot, snapshot})
  end

  @spec query(GenServer.server(), term()) ::
    {:ok, term()} | {:error, term()}
  def query(server, key) do
    GenServer.call(server, {:query, key})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, log_store} <- Keyword.fetch(opts, :log_store),
         {:ok, snapshot_dir} <- Keyword.fetch(opts, :snapshot_dir) do

      state = %State{
        node_id: node_id,
        log_store: log_store,
        snapshot_dir: snapshot_dir,
        last_applied_index: 0,
        last_snapshot_index: 0,
        last_snapshot_term: 0,
        data: %{}
      }

      {:ok, maybe_restore_latest_snapshot(state)}
    else
      :error -> {:stop, :missing_required_options}
      error -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:apply_entries, entries, commit_index}, _from, state) do
    case apply_new_entries(entries, commit_index, state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.last_applied_index}, new_state}
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state.data}, state}
  end

  def handle_call(:create_snapshot, _from, state) do
    snapshot = {state.last_applied_index, state.data}
    case write_snapshot(snapshot, state) do
      :ok ->
        new_state = %{state |
          last_snapshot_index: state.last_applied_index,
          last_snapshot_term: get_term_for_index(state.last_applied_index, state)
        }
        {:reply, {:ok, snapshot}, new_state}
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:restore_snapshot, {index, data} = snapshot}, _from, state) do
      if valid_snapshot?(snapshot, state) do
        case write_snapshot(snapshot, state) do
          :ok ->
            new_state = %{state |
              data: data,
              last_applied_index: index,
              last_snapshot_index: index,
              # Don't try to get term from log store if it's nil
              last_snapshot_term: if(state.log_store, do: get_term_for_index(index, state), else: 0)
            }
            {:reply, :ok, new_state}
          {:error, _} = error ->
            {:reply, error, state}
        end
      else
        {:reply, {:error, :invalid_snapshot}, state}
      end
    end

  def handle_call({:query, key}, _from, state) do
    result = Map.get(state.data, key, {:error, :not_found})
    {:reply, {:ok, result}, state}
  end

  # Private Functions

  defp apply_new_entries(entries, commit_index, state) do
      with :ok <- validate_entries(entries, state),
           {:ok, applicable_entries} <- filter_applicable_entries(entries, commit_index, state) do
        try do
          new_data = Enum.reduce(applicable_entries, state.data, &apply_entry/2)
          new_state = %{state |
            data: new_data,
            last_applied_index: commit_index
          }
          {:ok, new_state}
        rescue
          e -> {:error, {:command_application_failed, e}}
        end
      end
    end

  defp filter_applicable_entries(entries, commit_index, state) do
      applicable = entries
      |> Enum.filter(&(&1.index > state.last_applied_index))
      |> Enum.filter(&(&1.index <= commit_index))
      |> Enum.sort_by(& &1.index)

      {:ok, applicable}
    end

  defp validate_entries(entries, state) do
    if Enum.all?(entries, &valid_entry?(&1, state)) do
      :ok
    else
      {:error, :invalid_entries}
    end
  end

  defp valid_entry?(%LogEntry{index: index}, state) do
    index > state.last_applied_index
  end

  # defp filter_applicable_entries(entries, state) do
  #   applicable = Enum.filter(entries, &(&1.index > state.last_applied_index))
  #   {:ok, applicable}
  # end

  defp apply_entry(%LogEntry{command: command}, state_data) do
    case command do
      {:set, key, value} -> Map.put(state_data, key, value)
      {:delete, key} -> Map.delete(state_data, key)
      {:get, _key} -> state_data  # Read operations don't modify state
      _ -> raise "Unknown command: #{inspect(command)}"
    end
  end

  defp write_snapshot({index, data}, state) do
    snapshot_path = snapshot_path(state, index)
    binary_data = :erlang.term_to_binary({index, data})

    with :ok <- File.mkdir_p(Path.dirname(snapshot_path)),
         :ok <- File.write(snapshot_path, binary_data) do
      :ok
    else
      {:error, reason} -> {:error, {:snapshot_write_failed, reason}}
    end
  end

  defp maybe_restore_latest_snapshot(state) do
    case find_latest_snapshot(state) do
      {:ok, snapshot} ->
        {index, data} = snapshot
        %{state |
          data: data,
          last_applied_index: index,
          last_snapshot_index: index,
          last_snapshot_term: get_term_for_index(index, state)
        }
      _ -> state
    end
  end

  defp find_latest_snapshot(state) do
    snapshot_pattern = Path.join(state.snapshot_dir, "snapshot_*.dat")

    case Path.wildcard(snapshot_pattern) |> Enum.sort() |> List.last() do
      nil -> {:error, :no_snapshot}
      path ->
        try do
          data = path
          |> File.read!()
          |> :erlang.binary_to_term()
          {:ok, data}
        rescue
          _ -> {:error, :corrupt_snapshot}
        end
    end
  end

  defp valid_snapshot?({index, _data}, state) do
    index >= state.last_snapshot_index
  end

  defp snapshot_path(state, index) do
    Path.join(state.snapshot_dir, "snapshot_#{index}.dat")
  end

  defp get_term_for_index(index, %{log_store: nil}), do: 0
    defp get_term_for_index(index, %{log_store: log_store}) do
      case LogStore.get_entry(log_store, index) do
        {:ok, entry} -> entry.term
        _ -> 0
      end
    end

  defp last_entry_index([]), do: 0
  defp last_entry_index(entries), do: List.last(entries).index

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
