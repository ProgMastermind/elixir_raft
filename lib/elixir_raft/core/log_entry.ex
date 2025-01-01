defmodule ElixirRaft.Core.LogEntry do
  @moduledoc """
  Represents an entry in the Raft log. Each entry contains:
  - index: The position in the log (1-based)
  - term: The term when the entry was created
  - command: The command to be applied to the state machine
  - type: The type of entry (command or configuration change)
  """

  alias ElixirRaft.Core.Term

  @type command :: term()
  @type entry_type :: :command | :config_change
  @type index :: pos_integer()

  @type t :: %__MODULE__{
    index: index(),
    term: Term.t(),
    command: command(),
    type: entry_type(),
    created_at: DateTime.t()
  }

  defstruct [:index, :term, :command, :type, :created_at]

  @doc """
  Creates a new log entry.

  ## Parameters
  - index: Position in the log (must be positive)
  - term: Term when entry was created
  - command: Command to be applied
  - opts: Additional options
    - type: Entry type (default: :command)

  ## Returns
  {:ok, entry} on success, {:error, reason} on failure
  """
  @spec new(index(), Term.t(), command(), keyword()) ::
    {:ok, t()} | {:error, String.t()}
  def new(index, term, command, opts \\ []) do
    type = Keyword.get(opts, :type, :command)

    with :ok <- validate_index(index),
         {:ok, _} <- Term.validate(term),
         :ok <- validate_type(type) do
      entry = %__MODULE__{
        index: index,
        term: term,
        command: command,
        type: type,
        created_at: DateTime.utc_now()
      }
      {:ok, entry}
    end
  end

  @doc """
  Creates a new log entry, raising on invalid input.
  """
  @spec new!(index(), Term.t(), command(), keyword()) :: t() | no_return()
  def new!(index, term, command, opts \\ []) do
    case new(index, term, command, opts) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  @doc """
  Compares two log entries for replication purposes.
  Returns true if entries have same index and term.
  """
  @spec same_entry?(t(), t()) :: boolean()
  def same_entry?(%__MODULE__{} = entry1, %__MODULE__{} = entry2) do
    entry1.index == entry2.index && entry1.term == entry2.term
  end

  @doc """
  Checks if an entry is from a more recent term than another entry.
  """
  @spec more_recent_term?(t(), t()) :: boolean()
  def more_recent_term?(%__MODULE__{} = entry1, %__MODULE__{} = entry2) do
    Term.greater_than?(entry1.term, entry2.term)
  end

  @doc """
  Validates that one entry comes directly before another in the log.
  """
  @spec is_next?(t(), t()) :: boolean()
  def is_next?(%__MODULE__{} = prev_entry, %__MODULE__{} = next_entry) do
    next_entry.index == prev_entry.index + 1
  end

  @doc """
  Serializes a log entry for storage or network transmission.
  """
  @spec serialize(t()) :: map()
    def serialize(%__MODULE__{} = entry) do
      %{
        index: entry.index,
        term: entry.term,
        command: serialize_command(entry.command),
        type: Atom.to_string(entry.type),  # Convert atom to string for safer serialization
        created_at: DateTime.to_iso8601(entry.created_at)
      }
    end

  @doc """
  Deserializes a log entry from storage or network transmission.
  """
  @spec deserialize(map()) :: {:ok, t()} | {:error, String.t()}
    def deserialize(data) when is_map(data) do
      with {:ok, type} <- deserialize_type(data.type),
           {:ok, created_at, _offset} <- DateTime.from_iso8601(data.created_at) do
        entry = %__MODULE__{
          index: data.index,
          term: data.term,
          command: deserialize_command(data.command),
          type: type,
          created_at: created_at
        }
        {:ok, entry}
      else
        {:error, reason} -> {:error, "Invalid entry data: #{inspect(reason)}"}
        _ -> {:error, "Invalid entry data format"}
      end
    end

  def deserialize(_), do: {:error, "Invalid entry data format"}

  # Private functions

  defp validate_index(index) when is_integer(index) and index > 0, do: :ok
  defp validate_index(_), do: {:error, "Index must be a positive integer"}

  defp validate_type(type) when type in [:command, :config_change], do: :ok
  defp validate_type(_), do: {:error, "Invalid entry type"}

  defp deserialize_type("command"), do: {:ok, :command}
  defp deserialize_type("config_change"), do: {:ok, :config_change}
  defp deserialize_type(_), do: {:error, "Invalid entry type"}

  defp serialize_command(command) do
    # In a real implementation, you might want to use a more sophisticated
    # serialization mechanism based on your command types
    :erlang.term_to_binary(command)
  end

  defp deserialize_command(command_binary) do
    :erlang.binary_to_term(command_binary)
  end
end
