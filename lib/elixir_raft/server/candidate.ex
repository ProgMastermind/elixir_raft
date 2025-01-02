defmodule ElixirRaft.Server.Candidate do
  @moduledoc """
  Implementation of the Candidate role in the Raft consensus protocol.
  A candidate:
  1. Starts elections to try to become leader
  2. Sends RequestVote RPCs to other servers
  3. Collects votes until:
     - It wins the election and becomes leader
     - Another server establishes itself as leader
     - Election timeout occurs
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  alias ElixirRaft.Core.{ServerState, Term}
  alias ElixirRaft.RPC.Messages.{
    RequestVoteResponse,
    AppendEntriesResponse
  }

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
      election_timeout: pos_integer(),
      election_timer_ref: reference() | nil,
      votes_received: MapSet.t()
    }

    defstruct [
      :election_timeout,
      :election_timer_ref,
      :votes_received
    ]
  end

  @min_timeout 150
  @max_timeout 300

  @impl true
  def init(server_state) do
    # Start election by incrementing term and voting for self
    {:ok, next_term_state} = ServerState.maybe_update_term(
      server_state,
      Term.increment(server_state.current_term)
    )

    {:ok, voted_state} = ServerState.record_vote_for(
      next_term_state,
      next_term_state.node_id,
      next_term_state.current_term
    )

    state = %State{
      election_timeout: random_timeout(),
      votes_received: MapSet.new([voted_state.node_id])
    }

    {:ok, start_election_timer(state)}
  end

  @impl true
  def handle_append_entries(message, server_state, candidate_state) do
    case Term.compare(message.term, server_state.current_term) do
      :lt ->
        # Reject old term
        response = AppendEntriesResponse.new(
          server_state.current_term,
          false,
          server_state.node_id,
          0
        )
        {:ok, server_state, candidate_state, response}

      _ ->
        # Step down for equal or higher term
        {:transition, :follower, server_state, candidate_state}
    end
  end

  @impl true
  def handle_request_vote(message, server_state, candidate_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down for higher term
        {:transition, :follower, server_state, candidate_state}

      _ ->
        # Reject - already voted for self in current term
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
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down for higher term
        {:transition, :follower, server_state, candidate_state}

      :eq when message.vote_granted ->
        # Record vote and check for majority
        new_candidate_state = record_vote(candidate_state, message.voter_id)

        if has_majority?(new_candidate_state) do
          {:transition, :leader, server_state, new_candidate_state}
        else
          {:ok, server_state, new_candidate_state}
        end

      _ ->
        # Ignore votes from other terms or rejected votes
        {:ok, server_state, candidate_state}
    end
  end

  @impl true
  def handle_append_entries_response(_message, server_state, candidate_state) do
    # Candidates don't handle append entries responses
    {:ok, server_state, candidate_state}
  end

  @impl true
  def handle_timeout(:election, server_state, _candidate_state) do
    # Start new election
    {:ok, next_term_state} = ServerState.maybe_update_term(
      server_state,
      Term.increment(server_state.current_term)
    )

    {:ok, voted_state} = ServerState.record_vote_for(
      next_term_state,
      next_term_state.node_id,
      next_term_state.current_term
    )

    new_state = %State{
      election_timeout: random_timeout(),
      votes_received: MapSet.new([voted_state.node_id])
    }

    {:ok, voted_state, start_election_timer(new_state)}
  end

  @impl true
  def handle_timeout(_other, server_state, candidate_state) do
    {:ok, server_state, candidate_state}
  end

  @impl true
  def handle_client_command(_command, _server_state, _candidate_state) do
    {:error, :no_leader}
  end

  # Private Functions

  defp record_vote(state, voter_id) do
    %{state | votes_received: MapSet.put(state.votes_received, voter_id)}
  end

  defp has_majority?(state) do
    cluster_size = Application.get_env(:elixir_raft, :cluster_size, 3)
    votes_needed = div(cluster_size, 2) + 1
    MapSet.size(state.votes_received) >= votes_needed
  end

  defp random_timeout do
    @min_timeout + :rand.uniform(@max_timeout - @min_timeout)
  end

  defp start_election_timer(%State{} = state) do
    if state.election_timer_ref, do: Process.cancel_timer(state.election_timer_ref)
    timer_ref = Process.send_after(self(), {:timeout, :election}, state.election_timeout)
    %{state | election_timer_ref: timer_ref}
  end
end
