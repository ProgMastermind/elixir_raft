defmodule ElixirRaft.RPC.Messages do
  @moduledoc """
  Defines all RPC message types used in the Raft consensus protocol.
  """

  alias ElixirRaft.Core.{LogEntry, Term, NodeId}

  # Common types for the module
  @type log_index :: non_neg_integer()
  @type success :: boolean()

  # Request Vote RPC
  defmodule RequestVote do
    @moduledoc """
    RequestVote RPC is sent by candidates to gather votes.
    """

    # Import parent module's types
    @type log_index :: ElixirRaft.RPC.Messages.log_index()

    @type t :: %__MODULE__{
      term: Term.t(),
      candidate_id: NodeId.t(),
      last_log_index: log_index(),
      last_log_term: Term.t()
    }

    @enforce_keys [:term, :candidate_id, :last_log_index, :last_log_term]
    defstruct [:term, :candidate_id, :last_log_index, :last_log_term]

    @spec new(Term.t(), NodeId.t(), log_index(), Term.t()) :: t()
    def new(term, candidate_id, last_log_index, last_log_term) do
      %__MODULE__{
        term: term,
        candidate_id: candidate_id,
        last_log_index: last_log_index,
        last_log_term: last_log_term
      }
    end
  end

  defmodule RequestVoteResponse do
    @moduledoc """
    Response to RequestVote RPC.
    """

    @type t :: %__MODULE__{
      term: Term.t(),
      vote_granted: boolean(),
      voter_id: NodeId.t()
    }

    @enforce_keys [:term, :vote_granted, :voter_id]
    defstruct [:term, :vote_granted, :voter_id]

    @spec new(Term.t(), boolean(), NodeId.t()) :: t()
    def new(term, vote_granted, voter_id) do
      %__MODULE__{
        term: term,
        vote_granted: vote_granted,
        voter_id: voter_id
      }
    end
  end

  defmodule AppendEntries do
    @moduledoc """
    AppendEntries RPC is used for log replication and as heartbeat.
    """

    # Import parent module's types
    @type log_index :: ElixirRaft.RPC.Messages.log_index()

    @type t :: %__MODULE__{
      term: Term.t(),
      leader_id: NodeId.t(),
      prev_log_index: log_index(),
      prev_log_term: Term.t(),
      entries: [LogEntry.t()],
      leader_commit: log_index()
    }

    @enforce_keys [:term, :leader_id, :prev_log_index, :prev_log_term, :entries, :leader_commit]
    defstruct [:term, :leader_id, :prev_log_index, :prev_log_term, :entries, :leader_commit]

    @spec new(Term.t(), NodeId.t(), log_index(), Term.t(), [LogEntry.t()], log_index()) :: t()
    def new(term, leader_id, prev_log_index, prev_log_term, entries, leader_commit) do
      %__MODULE__{
        term: term,
        leader_id: leader_id,
        prev_log_index: prev_log_index,
        prev_log_term: prev_log_term,
        entries: entries,
        leader_commit: leader_commit
      }
    end

    @spec heartbeat(Term.t(), NodeId.t(), log_index(), Term.t(), log_index()) :: t()
    def heartbeat(term, leader_id, prev_log_index, prev_log_term, leader_commit) do
      new(term, leader_id, prev_log_index, prev_log_term, [], leader_commit)
    end
  end

  defmodule AppendEntriesResponse do
    @moduledoc """
    Response to AppendEntries RPC.
    """

    # Import parent module's types
    @type log_index :: ElixirRaft.RPC.Messages.log_index()

    @type t :: %__MODULE__{
      term: Term.t(),
      success: boolean(),
      follower_id: NodeId.t(),
      match_index: log_index()
    }

    @enforce_keys [:term, :success, :follower_id, :match_index]
    defstruct [:term, :success, :follower_id, :match_index]

    @spec new(Term.t(), boolean(), NodeId.t(), log_index()) :: t()
    def new(term, success, follower_id, match_index) do
      %__MODULE__{
        term: term,
        success: success,
        follower_id: follower_id,
        match_index: match_index
      }
    end
  end

  @doc """
  Validates a RequestVote message.
  """
  @spec validate_request_vote(RequestVote.t()) :: :ok | {:error, String.t()}
  def validate_request_vote(%RequestVote{} = msg) do
    with {:ok, _} <- NodeId.validate(msg.candidate_id),
         :ok <- validate_term(msg.term),
         :ok <- validate_non_negative(msg.last_log_index, "Last log index"),
         :ok <- validate_non_negative(msg.last_log_term, "Last log term") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates an AppendEntries message.
  """
  @spec validate_append_entries(AppendEntries.t()) :: :ok | {:error, String.t()}
  def validate_append_entries(%AppendEntries{} = msg) do
    with {:ok, _} <- NodeId.validate(msg.leader_id),
         :ok <- validate_term(msg.term),
         :ok <- validate_non_negative(msg.prev_log_index, "Previous log index"),
         :ok <- validate_non_negative(msg.prev_log_term, "Previous log term"),
         :ok <- validate_non_negative(msg.leader_commit, "Leader commit"),
         :ok <- validate_entries(msg.entries) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(struct()) :: binary()
  def encode(message) do
    :erlang.term_to_binary(message)
  end

  @spec decode(binary()) :: {:ok, struct()} | {:error, String.t()}
  def decode(binary) do
    try do
      decoded = :erlang.binary_to_term(binary, [:safe])
      case validate_decoded_message(decoded) do
        :ok -> {:ok, decoded}
        {:error, _} = error -> error
      end
    rescue
      _ -> {:error, "Invalid message format"}
    end
  end

  # Private Functions

  defp validate_term(term) when is_integer(term) and term >= 0, do: :ok
  defp validate_term(_), do: {:error, "Term must be a non-negative integer"}

  defp validate_non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(_, field), do: {:error, "#{field} must be a non-negative integer"}

  defp validate_entries(entries) when is_list(entries), do: :ok
  defp validate_entries(_), do: {:error, "Entries must be a list"}

  defp validate_decoded_message(%RequestVote{} = msg), do: validate_request_vote(msg)
  defp validate_decoded_message(%AppendEntries{} = msg), do: validate_append_entries(msg)
  defp validate_decoded_message(%RequestVoteResponse{}), do: :ok
  defp validate_decoded_message(%AppendEntriesResponse{}), do: :ok
  defp validate_decoded_message(_), do: {:error, "Unknown message type"}
end
