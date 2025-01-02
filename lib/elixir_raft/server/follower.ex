defmodule ElixirRaft.Server.Follower do
  @moduledoc """
  Implementation of the Follower role in the Raft consensus protocol.
  Followers are passive: they respond to RPCs from leaders and candidates.
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  alias ElixirRaft.Core.{ServerState, Term}
  alias ElixirRaft.RPC.Messages.{
    AppendEntriesResponse,
    RequestVoteResponse
  }

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
      election_timeout: pos_integer(),
      election_timer_ref: reference() | nil
    }

    defstruct [:election_timeout, :election_timer_ref]
  end

  @min_timeout 150
  @max_timeout 300

  @impl true
  def init(_server_state) do
    {:ok, start_election_timer(%State{
      election_timeout: random_timeout()
    })}
  end

  @impl true
  def handle_append_entries(message, server_state, follower_state) do
    case Term.compare(message.term, server_state.current_term) do
      :lt ->
        # Reject if term is less than current term
        response = AppendEntriesResponse.new(
          server_state.current_term,
          false,
          server_state.node_id,
          0
        )
        {:ok, server_state, follower_state, response}

      _ ->
        # Accept and update term if needed
        {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)
        {:ok, with_leader} = ServerState.record_leader_contact(updated_state, message.leader_id)

        # Check log consistency
        log_ok = case message.prev_log_index do
          0 -> true
          _ ->
            case ServerState.get_log_entry(with_leader, message.prev_log_index) do
              {:ok, entry} -> entry.term == message.prev_log_term
              {:error, _} -> false
            end
        end

        if log_ok do
          # Update log and commit index
          {:ok, state_with_entries} = ServerState.append_entries(
            with_leader,
            message.prev_log_index,
            message.entries
          )

          # Update commit index based on leader's commit index
          {:ok, final_state} = ServerState.update_commit_index(
            state_with_entries,
            min(message.leader_commit, message.prev_log_index + length(message.entries))
          )

          # Reset election timer as we heard from valid leader
          new_follower_state = reset_election_timer(follower_state)

          response = AppendEntriesResponse.new(
            final_state.current_term,
            true,
            final_state.node_id,
            message.prev_log_index + length(message.entries)
          )

          {:ok, final_state, new_follower_state, response}
        else
          response = AppendEntriesResponse.new(
            with_leader.current_term,
            false,
            with_leader.node_id,
            0
          )
          {:ok, with_leader, follower_state, response}
        end
    end
  end

  @impl true
  def handle_request_vote(message, server_state, follower_state) do
    case Term.compare(message.term, server_state.current_term) do
      :lt ->
        # Reject if term is less than current term
        response = RequestVoteResponse.new(
          server_state.current_term,
          false,
          server_state.node_id
        )
        {:ok, server_state, follower_state, response}

      _ ->
        {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)

        grant_vote? = can_grant_vote?(updated_state, message.candidate_id)

        if grant_vote? do
          {:ok, voted_state} = ServerState.record_vote_for(
            updated_state,
            message.candidate_id,
            message.term
          )

          response = RequestVoteResponse.new(
            voted_state.current_term,
            true,
            voted_state.node_id
          )
          {:ok, voted_state, follower_state, response}
        else
          response = RequestVoteResponse.new(
            updated_state.current_term,
            false,
            updated_state.node_id
          )
          {:ok, updated_state, follower_state, response}
        end
    end
  end

  @impl true
  def handle_append_entries_response(_message, server_state, follower_state) do
    # Followers don't handle AppendEntries responses
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_request_vote_response(_message, server_state, follower_state) do
    # Followers don't handle RequestVote responses
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_timeout(:election, server_state, follower_state) do
    {:transition, :candidate, server_state, follower_state}
  end

  @impl true
  def handle_timeout(_other, server_state, follower_state) do
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_client_command(_command, server_state, follower_state) do
    case server_state.current_leader do
      nil -> {:error, :no_leader}
      leader_id -> {:redirect, leader_id, server_state, follower_state}
    end
  end

  # Private Functions

  defp can_grant_vote?(server_state, candidate_id) do
    server_state.voted_for == nil || server_state.voted_for == candidate_id
  end

  defp random_timeout do
    @min_timeout + :rand.uniform(@max_timeout - @min_timeout)
  end

  defp start_election_timer(%State{} = state) do
    if state.election_timer_ref, do: Process.cancel_timer(state.election_timer_ref)
    timer_ref = Process.send_after(self(), {:timeout, :election}, state.election_timeout)
    %{state | election_timer_ref: timer_ref}
  end

  defp reset_election_timer(%State{} = state) do
    start_election_timer(%{state | election_timeout: random_timeout()})
  end
end
