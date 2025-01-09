defmodule ElixirRaft.Core.ServerState do
  @moduledoc """
  Manages the core state of a Raft server including:
  - Term management
  - Role transitions
  - Voting
  - Log management
  - Leadership tracking
  - Commit index
  """

  alias ElixirRaft.Core.{Term, NodeId, LogEntry}

  @type role :: :follower | :candidate | :leader
  @type vote_state :: %{
    term: Term.t(),
    votes_received: MapSet.t(),
    votes_granted: MapSet.t()
  }

  @type t :: %__MODULE__{
    node_id: NodeId.t(),
    current_term: Term.t(),
    role: role(),
    voted_for: NodeId.t() | nil,
    current_leader: NodeId.t() | nil,
    vote_state: vote_state() | nil,
    last_leader_contact: integer() | nil,
    log: [LogEntry.t()],
    commit_index: non_neg_integer()
  }

  defstruct [
    :node_id,
    :current_term,
    :role,
    :voted_for,
    :current_leader,
    :vote_state,
    :last_leader_contact,
    log: [],
    commit_index: 0
  ]

  @doc """
  Creates a new server state with the given node ID.
  Initializes as follower with term 0.
  """
  @spec new(NodeId.t()) :: t()
  def new(node_id) do
    %__MODULE__{
        node_id: node_id,
        current_term: 0,
        role: :follower,
        voted_for: nil,
        current_leader: nil,
        vote_state: nil,
        last_leader_contact: nil
      }
  end

  @doc """
  Updates the term if the new term is higher than the current term.
  When term is updated, server converts to follower and clears vote.
  """
  @spec maybe_update_term(t(), Term.t()) :: {:ok, t()} | {:error, String.t()}
  def maybe_update_term(%__MODULE__{} = state, new_term) do
    case Term.compare(new_term, state.current_term) do
      :gt ->
        {:ok, %{state |
          current_term: new_term,
          role: :follower,
          voted_for: nil,
          current_leader: nil,
          vote_state: nil
        }}
      _ ->
        {:ok, state}
    end
  end

  @doc """
  Gets a log entry at the specified index.
  Returns {:ok, entry} if found, {:error, :not_found} if not.
  """
  @spec get_log_entry(t(), non_neg_integer()) :: {:ok, LogEntry.t()} | {:error, :not_found}
  def get_log_entry(%__MODULE__{log: log}, index) when index > 0 do
    case Enum.at(log, index - 1) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def get_log_entry(_, _), do: {:error, :not_found}

  @doc """
  Gets the last log entry.
  Returns {:ok, entry} if log is not empty, {:error, :not_found} if empty.
  """
  @spec get_last_log_entry(t()) :: {:ok, LogEntry.t()} | {:error, :not_found}
  def get_last_log_entry(%__MODULE__{log: []}), do: {:error, :not_found}
  def get_last_log_entry(%__MODULE__{log: log}), do: {:ok, List.last(log)}

  @doc """
  Gets the term of the last log entry, or 0 if log is empty.
  """
  @spec get_last_log_term(t()) :: Term.t()
  def get_last_log_term(%__MODULE__{log: []}) do
    0
  end
  def get_last_log_term(%__MODULE__{log: log}) do
    last_entry = List.last(log)
    last_entry.term
  end

  @doc """
  Gets the index of the last log entry, or 0 if log is empty.
  """
  @spec get_last_log_index(t()) :: non_neg_integer()
  def get_last_log_index(%__MODULE__{log: []}), do: 0
  def get_last_log_index(%__MODULE__{log: log}), do: length(log)

  @doc """
  Appends entries to the log starting at prev_log_index + 1.
  If there are existing entries that conflict with the new ones, they are truncated.
  """
  @spec append_entries(t(), non_neg_integer(), [LogEntry.t()]) :: {:ok, t()} | {:error, String.t()}
  def append_entries(%__MODULE__{} = state, prev_log_index, new_entries) do
    with :ok <- validate_prev_log_index(state, prev_log_index) do
      # Truncate any conflicting entries and append new ones
      existing_log = Enum.take(state.log, prev_log_index)
      new_log = existing_log ++ new_entries

      {:ok, %{state | log: new_log}}
    end
  end

  @doc """
  Updates the commit index if the new value is higher than the current one.
  Will not allow commit index to exceed the last log entry.
  """
  @spec update_commit_index(t(), non_neg_integer()) :: {:ok, t()} | {:error, String.t()}
  def update_commit_index(%__MODULE__{} = state, new_index) do
    last_index = get_last_log_index(state)

    cond do
      new_index < state.commit_index ->
        {:error, "New commit index cannot be lower than current commit index"}

      new_index > last_index ->
        {:error, "Cannot commit beyond last log entry"}

      true ->
        {:ok, %{state | commit_index: new_index}}
    end
  end


  @spec get_entries_from(t(), non_neg_integer()) :: {:ok, [LogEntry.t()]}
  def get_entries_from(%__MODULE__{log: log}, start_index) when start_index > 0 do
    # Calculate the list index (0-based) from the log index (1-based)
    list_index = start_index - 1

    # Ensure the list index is within bounds
    entries =
      if list_index < length(log) do
        Enum.slice(log, list_index..-1//1)
      else
        []
      end

    {:ok, entries}
  end

    def get_entries_from(%__MODULE__{}, _), do: {:ok, []}

  @doc """
  Records the vote given by this server to a candidate.
  """
  @spec record_vote_for(t(), NodeId.t(), Term.t()) :: {:ok, t()} | {:error, String.t()}
  def record_vote_for(%__MODULE__{} = state, candidate_id, term) do
    cond do
      term != state.current_term ->
        {:error, "Vote for different term"}

      state.voted_for != nil && state.voted_for != candidate_id ->
        {:error, "Already voted for different candidate in current term"}

      true ->
        {:ok, %{state | voted_for: candidate_id}}
    end
  end

  @doc """
  Records a vote received from another server during an election.
  Only valid for candidates.
  """
  @spec record_vote(t(), NodeId.t(), boolean()) :: {:ok, t()} | {:error, String.t()}
  def record_vote(%__MODULE__{role: :candidate} = state, voter_id, granted) do
    if state.vote_state.term == state.current_term do
      vote_state = %{state.vote_state |
        votes_received: MapSet.put(state.vote_state.votes_received, voter_id),
        votes_granted: if(granted,
          do: MapSet.put(state.vote_state.votes_granted, voter_id),
          else: state.vote_state.votes_granted
        )
      }
      {:ok, %{state | vote_state: vote_state}}
    else
      {:error, "Vote from outdated term"}
    end
  end

  def record_vote(%__MODULE__{}, _, _) do
    {:error, "Only candidates can record votes"}
  end

  @doc """
  Records contact from a leader, updating the leader ID and timestamp.
  """
  @spec record_leader_contact(t(), NodeId.t()) :: {:ok, t()}
  def record_leader_contact(%__MODULE__{} = state, leader_id) do
    {:ok, %{state |
      current_leader: leader_id,
      last_leader_contact: System.monotonic_time(:millisecond)
    }}
  end

  # Private Functions

  defp validate_prev_log_index(state, prev_log_index) do
    cond do
      prev_log_index < 0 ->
        {:error, "Previous log index cannot be negative"}

      prev_log_index > get_last_log_index(state) ->
        {:error, "Previous log index beyond current log"}

      true ->
        :ok
    end
  end
end
