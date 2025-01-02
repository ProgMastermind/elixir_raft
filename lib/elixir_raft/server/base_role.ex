defmodule ElixirRaft.Server.BaseRole do
  @moduledoc """
  Provides common functionality for all Raft server roles.
  """

  alias ElixirRaft.Core.{Term, NodeId}
  alias ElixirRaft.RPC.Messages.{RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse}
  alias ElixirRaft.Storage.LogStore

  @type log_index :: non_neg_integer()

  defmodule BaseState do
    @moduledoc """
    Common state maintained by all roles.
    """
    @type t :: %__MODULE__{
      node_id: NodeId.t(),
      current_term: Term.t(),
      voted_for: NodeId.t() | nil,
      log_store: GenServer.server(),
      last_applied: non_neg_integer(),
      commit_index: non_neg_integer(),
      leader_id: NodeId.t() | nil
    }

    defstruct [
      :node_id,
      :current_term,
      :voted_for,
      :log_store,
      :last_applied,
      :commit_index,
      :leader_id
    ]
  end

  @doc """
  Validates that an incoming RPC's term is current.
  """
  @spec validate_term(Term.t(), BaseState.t()) ::
    {:ok, BaseState.t()} | {:transition, :follower, BaseState.t()}
  def validate_term(msg_term, state) do
    cond do
      msg_term > state.current_term ->
        new_state = %{state |
          current_term: msg_term,
          voted_for: nil,
          leader_id: nil
        }
        {:transition, :follower, new_state}
      true ->
        {:ok, state}
    end
  end

  @doc """
  Updates the commit index and applies log entries.
  """
  @spec maybe_advance_commit_index(log_index(), BaseState.t()) :: BaseState.t()
  def maybe_advance_commit_index(leader_commit, state) when leader_commit > state.commit_index do
    {:ok, {last_index, _}} = LogStore.get_last_entry_info(state.log_store)
    new_commit_index = min(leader_commit, last_index)

    if new_commit_index > state.commit_index do
      %{state | commit_index: new_commit_index}
    else
      state
    end
  end
  def maybe_advance_commit_index(_, state), do: state

  @doc """
  Checks if the candidate's log is at least as up-to-date as the current log.
  """
  @spec is_log_up_to_date?(log_index(), Term.t(), BaseState.t()) :: boolean()
  def is_log_up_to_date?(last_log_index, last_log_term, state) do
    {:ok, {local_last_index, local_last_term}} = LogStore.get_last_entry_info(state.log_store)

    cond do
      last_log_term > local_last_term -> true
      last_log_term < local_last_term -> false
      true -> last_log_index >= local_last_index
    end
  end

  @doc """
  Verifies log matching property for append entries.
  """
  @spec verify_log_matching?(log_index(), Term.t(), BaseState.t()) :: boolean()
  def verify_log_matching?(prev_log_index, prev_log_term, state) do
    case LogStore.get_entry(state.log_store, prev_log_index) do
      {:ok, entry} -> entry.term == prev_log_term
      {:error, :not_found} -> prev_log_index == 0
    end
  end
end
