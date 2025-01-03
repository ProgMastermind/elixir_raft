defmodule ElixirRaft.Storage.StateStore do
  @moduledoc """
  Persistent storage for critical Raft state.
  Ensures durability of:
  - Current term
  - Voted for candidate
  - Server configuration

  Guarantees atomic writes for state updates.
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.{Term, NodeId, ClusterConfig}

  @type state_data :: %{
    current_term: Term.t(),
    voted_for: NodeId.t() | nil,
    cluster_config: ClusterConfig.t() | nil
  }

  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :data_dir,
      :state_path,
      :lock_path,
      :sync_writes
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec get_current_term(GenServer.server()) :: {:ok, Term.t()} | {:error, term()}
  def get_current_term(server) do
    GenServer.call(server, :get_current_term)
  end

  @spec get_voted_for(GenServer.server()) :: {:ok, NodeId.t() | nil} | {:error, term()}
  def get_voted_for(server) do
    GenServer.call(server, :get_voted_for)
  end

  @spec get_cluster_config(GenServer.server()) :: {:ok, ClusterConfig.t() | nil} | {:error, term()}
  def get_cluster_config(server) do
    GenServer.call(server, :get_cluster_config)
  end

  @spec save_term(GenServer.server(), Term.t()) :: :ok | {:error, term()}
  def save_term(server, term) do
    GenServer.call(server, {:save_term, term})
  end

  @spec save_vote(GenServer.server(), NodeId.t() | nil) :: :ok | {:error, term()}
  def save_vote(server, voted_for) do
    GenServer.call(server, {:save_vote, voted_for})
  end

  @spec save_cluster_config(GenServer.server(), ClusterConfig.t()) :: :ok | {:error, term()}
  def save_cluster_config(server, config) do
    GenServer.call(server, {:save_cluster_config, config})
  end

  @spec save_state(GenServer.server(), state_data()) :: :ok | {:error, term()}
  def save_state(server, state_data) do
    GenServer.call(server, {:save_state, state_data})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, state} <- init_state(opts),
         :ok <- ensure_data_dir(state),
         {:ok, _} <- load_or_init_state(state) do
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize state store: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_current_term, _from, state) do
    case read_state_file(state) do
      {:ok, data} -> {:reply, {:ok, data.current_term}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:get_voted_for, _from, state) do
    case read_state_file(state) do
      {:ok, data} -> {:reply, {:ok, data.voted_for}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:get_cluster_config, _from, state) do
    case read_state_file(state) do
      {:ok, data} -> {:reply, {:ok, data.cluster_config}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:save_term, term}, _from, state) do
    with {:ok, current_data} <- read_state_file(state),
         :ok <- validate_term(term),
         :ok <- write_state_file(%{current_data | current_term: term}, state) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:save_vote, voted_for}, _from, state) do
    with {:ok, current_data} <- read_state_file(state),
         :ok <- validate_vote(voted_for),
         :ok <- write_state_file(%{current_data | voted_for: voted_for}, state) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:save_cluster_config, config}, _from, state) do
    with {:ok, current_data} <- read_state_file(state),
         :ok <- validate_config(config),
         :ok <- write_state_file(%{current_data | cluster_config: config}, state) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:save_state, state_data}, _from, state) do
    with :ok <- validate_state_data(state_data),
         :ok <- write_state_file(state_data, state) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  # Private Functions

  defp init_state(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    data_dir = Keyword.fetch!(opts, :data_dir)

    {:ok, %State{
      node_id: node_id,
      data_dir: data_dir,
      state_path: Path.join(data_dir, "state.dat"),
      lock_path: Path.join(data_dir, "state.lock"),
      sync_writes: Keyword.get(opts, :sync_writes, true)
    }}
  end

  defp ensure_data_dir(%State{data_dir: dir}) do
    File.mkdir_p(dir)
  end

  defp load_or_init_state(state) do
    case read_state_file(state) do
      {:ok, _data} = result -> result
      {:error, :enoent} -> init_state_file(state)
      {:error, :corrupt_data} -> init_state_file(state)  # Initialize on corruption
      error -> error
    end
  end

  defp init_state_file(state) do
    initial_data = %{
      current_term: 0,
      voted_for: nil,
      cluster_config: nil
    }
    case write_state_file(initial_data, state) do
      :ok -> {:ok, initial_data}
      error -> error
    end
  end

  defp read_state_file(%State{state_path: path}) do
    case File.read(path) do
      {:ok, contents} ->
        try do
          data = :erlang.binary_to_term(contents)
          {:ok, data}
        rescue
          _ -> {:error, :corrupt_data}
        end
      {:error, _} = error -> error
    end
  end

  defp write_state_file(data, %State{state_path: path, lock_path: lock_path, sync_writes: sync_writes}) do
    lock_file = Path.basename(lock_path)
    tmp_file = path <> ".tmp"

    with :ok <- File.write(lock_path, "", [:write]),
         :ok <- write_atomic(tmp_file, data, sync_writes),
         :ok <- File.rename(tmp_file, path),
         :ok <- File.rm(lock_path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to write state file: #{inspect(reason)}")
        cleanup_failed_write(tmp_file, lock_file)
        {:error, reason}
    end
  end

  defp write_atomic(path, data, sync_writes) do
    binary = :erlang.term_to_binary(data)
    write_opts = if sync_writes, do: [:write, :sync], else: [:write]
    File.write(path, binary, write_opts)
  end

  defp cleanup_failed_write(tmp_file, lock_file) do
    File.rm(tmp_file)
    File.rm(lock_file)
  end

  defp validate_term(term) do
    case Term.validate(term) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_vote(nil), do: :ok
  defp validate_vote(voted_for) do
    case NodeId.validate(voted_for) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_config(nil), do: :ok
  defp validate_config(%ClusterConfig{}), do: :ok
  defp validate_config(_), do: {:error, :invalid_config}

  defp validate_state_data(%{current_term: term, voted_for: voted_for, cluster_config: config}) do
    with :ok <- validate_term(term),
         :ok <- validate_vote(voted_for),
         :ok <- validate_config(config) do
      :ok
    end
  end
  defp validate_state_data(_), do: {:error, :invalid_state_data}

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
