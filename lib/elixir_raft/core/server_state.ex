defmodule ElixirRaft.Core.ServerState do
  @moduledoc """
  Manages the core state of a Raft server including:
  - Current term
  - Current role (Follower/Candidate/Leader)
  - Voted for information
  - Current leader
  - Vote counting for elections
  """

  alias ElixirRaft.Core.{Term, NodeId}

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
    last_leader_contact: integer() | nil  # Timestamp of last leader contact
  }

  defstruct [
    :node_id,
    :current_term,
    :role,
    :voted_for,
    :current_leader,
    :vote_state,
    :last_leader_contact
  ]

  @doc """
  Creates a new server state initialized as a follower.
  """
  @spec new(NodeId.t()) :: t()
  def new(node_id) do
    %__MODULE__{
      node_id: node_id,
      current_term: Term.new(),
      role: :follower,
      voted_for: nil,
      current_leader: nil,
      vote_state: nil,
      last_leader_contact: nil
    }
  end

  @doc """
  Updates the term if the new term is greater than the current term.
  According to Raft, if a server discovers a greater term, it must:
  1. Update its term
  2. Convert to follower
  3. Clear its vote
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
  Transitions the server to candidate state and starts a new election.
  According to Raft:
  1. Increment current term
  2. Vote for self
  3. Reset election timeout
  4. Send RequestVote RPCs to all other servers
  """
  @spec become_candidate(t()) :: {:ok, t()} | {:error, String.t()}
  def become_candidate(%__MODULE__{} = state) do
    new_term = Term.increment(state.current_term)

    {:ok, %{state |
      current_term: new_term,
      role: :candidate,
      voted_for: state.node_id,
      current_leader: nil,
      vote_state: %{
        term: new_term,
        votes_received: MapSet.new([state.node_id]),
        votes_granted: MapSet.new([state.node_id])
      }
    }}
  end

  @doc """
  Transitions the server to leader state.
  According to Raft, this happens when a candidate:
  1. Receives votes from a majority of servers
  2. Converts to leader
  """
  @spec become_leader(t()) :: {:ok, t()} | {:error, String.t()}
  def become_leader(%__MODULE__{role: :candidate} = state) do
    {:ok, %{state |
      role: :leader,
      current_leader: state.node_id,
      vote_state: nil
    }}
  end

  def become_leader(%__MODULE__{} = _state) do
    {:error, "Only candidates can become leader"}
  end

  @doc """
  Records a vote received from another server during an election.
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
  Records contact from a valid leader to reset election timeout.
  """
  @spec record_leader_contact(t(), NodeId.t()) :: {:ok, t()} | {:error, String.t()}
  def record_leader_contact(%__MODULE__{} = state, leader_id) do
    {:ok, %{state |
      current_leader: leader_id,
      last_leader_contact: System.monotonic_time(:millisecond)
    }}
  end

  @doc """
  Checks if the server has received enough votes to become leader.
  """
  @spec has_quorum?(t(), integer()) :: boolean()
  def has_quorum?(%__MODULE__{role: :candidate} = state, cluster_size) do
    votes_needed = div(cluster_size, 2) + 1
    MapSet.size(state.vote_state.votes_granted) >= votes_needed
  end

  def has_quorum?(%__MODULE__{}, _), do: false

  @doc """
  Returns true if the server hasn't heard from a leader recently.
  """
  @spec leader_timed_out?(t(), integer()) :: boolean()
  def leader_timed_out?(%__MODULE__{last_leader_contact: nil}, _), do: true
  def leader_timed_out?(%__MODULE__{} = state, timeout_ms) do
    now = System.monotonic_time(:millisecond)
    now - state.last_leader_contact >= timeout_ms
  end
end
