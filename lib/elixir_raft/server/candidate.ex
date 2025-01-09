defmodule ElixirRaft.Server.Candidate do
  @moduledoc """
  Implementation of the Candidate role in Raft.
  Candidates:
  - Start elections
  - Request votes from peers
  - Track received votes
  - Transition to leader if majority gained
  - Step down if leader is discovered
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  require Logger
  alias ElixirRaft.Core.{ServerState, Term, NodeId, ClusterInfo}
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    AppendEntriesResponse,
    RequestVote,
    RequestVoteResponse
  }

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
      election_timeout: pos_integer(),
      election_timer_ref: reference() | nil,
      votes_received: MapSet.t(),
      election_start: integer()
    }

    defstruct [
      :election_timeout,
      :election_timer_ref,
      :election_start,
      votes_received: MapSet.new()
    ]
  end

  @min_timeout 150
  @max_timeout 300

  #
  # Role Behaviour Implementation
  #

  @impl true
  def init(server_state) do
    # Start new election
    {:ok, next_term_state} = ServerState.maybe_update_term(
      server_state,
      Term.increment(server_state.current_term)
    )

    # Vote for self
    {:ok, voted_state} = ServerState.record_vote_for(
      next_term_state,
      next_term_state.node_id,
      next_term_state.current_term
    )

    # Initialize candidate state
    state = %State{
      election_timeout: random_timeout(),
      votes_received: MapSet.new([voted_state.node_id]),
      election_start: now()
    }

    # Create vote request
    request = create_vote_request(voted_state)

    # Return state and broadcast request
    {:ok, voted_state, start_election_timer(state), {:broadcast, request}}
  end

  @impl true
  def handle_append_entries(message, server_state, candidate_state) do
    case validate_append_entries(message, server_state) do
      :ok ->
        # Valid AppendEntries from new leader - step down
        Logger.info("Stepping down: received valid AppendEntries from leader",
          term: message.term,
          leader: message.leader_id
        )
        {:transition, :follower, server_state}

      {:error, :old_term} ->
        # Reject old term messages
        response = AppendEntriesResponse.new(
          server_state.current_term,
          false,
          server_state.node_id,
          0
        )
        {:ok, server_state, candidate_state, response}
    end
  end

  @impl true
  def handle_append_entries_response(_message, server_state, candidate_state) do
    # Candidates don't handle append entries responses
    {:ok, server_state, candidate_state}
  end

  @impl true
  def handle_request_vote(message, server_state, candidate_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Higher term - step down
        Logger.info("Stepping down: received RequestVote with higher term",
          current_term: server_state.current_term,
          new_term: message.term
        )
        {:transition, :follower, server_state}

      _ ->
        # Reject - already voted for self
        response = RequestVoteResponse.new(
          server_state.current_term,
          false,
          server_state.node_id
        )
        {:ok, server_state, candidate_state, response}
    end
  end

  @impl true
  def handle_request_vote_response(message, server_state, candidate_state) do
    case validate_vote_response(message, server_state) do
      :ok when message.vote_granted ->
        # Record vote and check for majority
        new_state = record_vote(candidate_state, message.voter_id)

        if has_majority?(new_state) do
          Logger.info("Won election",
            term: server_state.current_term,
            votes: MapSet.size(new_state.votes_received)
          )
          {:transition, :leader, server_state}
        else
          {:ok, server_state, new_state}
        end

      _ ->
        # Ignore invalid or negative votes
        {:ok, server_state, candidate_state}
    end
  end

  @impl true
  def handle_timeout(:election, server_state, candidate_state) do
    Logger.info("Election timeout - starting new election",
      term: server_state.current_term,
      votes: MapSet.size(candidate_state.votes_received)
    )
    # Start new election
    {:transition, :candidate, server_state}
  end

  def handle_timeout(_type, server_state, candidate_state) do
    {:ok, server_state, candidate_state}
  end

  @impl true
  def handle_client_command(_command, _server_state, _candidate_state) do
    {:error, :no_leader}
  end

  #
  # Private Functions
  #

  defp validate_append_entries(message, server_state) do
    case Term.compare(message.term, server_state.current_term) do
      :lt -> {:error, :old_term}
      _ -> :ok
    end
  end

  defp validate_vote_response(message, server_state) do
    cond do
      message.term != server_state.current_term ->
        {:error, :term_mismatch}
      server_state.vote_state &&
      MapSet.member?(server_state.vote_state.votes_received, message.voter_id) ->
        {:error, :duplicate_vote}
      true ->
        :ok
    end
  end

  defp create_vote_request(server_state) do
    RequestVote.new(
      server_state.current_term,
      server_state.node_id,
      ServerState.get_last_log_index(server_state),
      ServerState.get_last_log_term(server_state)
    )
  end

  defp record_vote(state, voter_id) do
    %{state | votes_received: MapSet.put(state.votes_received, voter_id)}
  end

  defp has_majority?(state) do
    votes_needed = ClusterInfo.majority_size()
    current_votes = MapSet.size(state.votes_received)

    Logger.debug("Vote count",
      current: current_votes,
      needed: votes_needed
    )

    current_votes >= votes_needed
  end

  defp random_timeout do
    @min_timeout + :rand.uniform(@max_timeout - @min_timeout)
  end

  defp start_election_timer(%State{} = state) do
    if state.election_timer_ref, do: Process.cancel_timer(state.election_timer_ref)
    timer_ref = Process.send_after(self(), {:timeout, :election}, state.election_timeout)
    %{state | election_timer_ref: timer_ref}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
