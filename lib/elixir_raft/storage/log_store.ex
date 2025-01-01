defmodule ElixirRaft.Storage.LogStore do
  @moduledoc """
  Persistent storage for Raft log entries.
  """

  use GenServer
  require Logger

  alias ElixirRaft.Core.LogEntry

  @type log_index :: non_neg_integer()
  @type store_options :: [
    data_dir: String.t(),
    sync_writes: boolean()
  ]

  defmodule State do
    @moduledoc false
    defstruct [
      :data_dir,
      :log_file,
      :index_file,
      :sync_writes,
      entries: [],
      last_index: 0,
      last_term: 0
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  def append(server, %LogEntry{} = entry) do
    GenServer.call(server, {:append, entry})
  end

  def get_entry(server, index) when is_integer(index) and index >= 0 do
    GenServer.call(server, {:get_entry, index})
  end

  def get_entries(server, start_index, end_index)
      when is_integer(start_index) and is_integer(end_index)
      and start_index <= end_index do
    GenServer.call(server, {:get_entries, start_index, end_index})
  end

  def truncate_after(server, index) do
    GenServer.call(server, {:truncate_after, index})
  end

  def get_last_entry_info(server) do
    GenServer.call(server, :get_last_entry_info)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    sync_writes = Keyword.get(opts, :sync_writes, true)

    with :ok <- ensure_data_dir(data_dir),
         {:ok, state} <- initialize_store(data_dir, sync_writes) do
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize log store: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, entry}, _from, state) do
    case validate_append(entry, state) do
      :ok ->
        case write_entry(entry, state) do
          {:ok, new_state} -> {:reply, {:ok, entry.index}, new_state}
          {:error, _} = error -> {:reply, error, state}
        end
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_entry, index}, _from, state) do
    result = Enum.find(state.entries, &(&1.index == index))
    case result do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:get_entries, start_index, end_index}, _from, state) do
    entries = state.entries
             |> Enum.filter(&(&1.index >= start_index and &1.index <= end_index))
    {:reply, {:ok, entries}, state}
  end

  def handle_call({:truncate_after, index}, _from, state) do
    case truncate_log(index, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:get_last_entry_info, _from, state) do
    {:reply, {:ok, {state.last_index, state.last_term}}, state}
  end

  # Private Functions

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end

  defp ensure_data_dir(dir) do
    File.mkdir_p(dir)
  end

  defp initialize_store(data_dir, sync_writes) do
      state = %State{
        data_dir: data_dir,
        log_file: Path.join(data_dir, "log.dat"),
        index_file: Path.join(data_dir, "index.dat"),
        sync_writes: sync_writes
      }

      case read_log_file(state.log_file) do
        {:ok, entries} ->
          last_entry = List.last(entries) || %{index: 0, term: 0}
          {:ok, %{state |
            entries: entries,
            last_index: last_entry.index,
            last_term: last_entry.term
          }}
        {:error, :enoent} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end

  defp read_log_file(file_path) do
      case File.read(file_path) do
        {:ok, ""} -> {:ok, []}
        {:ok, content} ->
          entries = content
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_entry/1)
          |> Enum.reject(&is_nil/1)
          {:ok, entries}
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end

  defp decode_entry(binary) do
      try do
        binary
        |> Base.decode64!()
        |> :erlang.binary_to_term([:safe])
      rescue
        _ -> nil
      end
    end

  defp validate_append(entry, state) do
    cond do
      entry.index != state.last_index + 1 ->
        {:error, "Invalid index: expected #{state.last_index + 1}, got #{entry.index}"}
      entry.index > 1 && entry.term < state.last_term ->
        {:error, "Invalid term: new term #{entry.term} is less than last term #{state.last_term}"}
      true ->
        :ok
    end
  end

  defp write_entry(entry, state) do
      binary = entry
      |> :erlang.term_to_binary()
      |> Base.encode64()

      case write_to_file(binary, state) do
        :ok ->
          new_state = %{state |
            entries: state.entries ++ [entry],
            last_index: entry.index,
            last_term: entry.term
          }
          {:ok, new_state}
        {:error, reason} -> {:error, reason}
      end
    end

  defp write_to_file(binary, state) do
      options = if state.sync_writes, do: [:append, :sync], else: [:append]
      File.write(state.log_file, binary <> "\n", options)
    end

    defp truncate_log(index, state) when is_integer(index) and index >= 0 do
      new_entries = Enum.take_while(state.entries, &(&1.index <= index))
      case rewrite_log_file(new_entries, state) do
        :ok ->
          last_entry = List.last(new_entries) || %{index: 0, term: 0}
          new_state = %{state |
            entries: new_entries,
            last_index: last_entry.index,
            last_term: last_entry.term
          }
          {:ok, new_state}
        error -> error
      end
    end

    defp truncate_log(_, _), do: {:error, "Invalid truncate index"}

    defp rewrite_log_file(entries, state) do
      content = entries
      |> Enum.map(fn entry ->
        entry
        |> :erlang.term_to_binary()
        |> Base.encode64()
      end)
      |> Enum.join("\n")

      options = if state.sync_writes, do: [:write, :sync], else: [:write]
      case File.write(state.log_file, content <> if(content != "", do: "\n", else: ""), options) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
end
