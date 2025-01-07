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
        election_timer_ref: reference() | nil,
        last_leader_contact: integer() | nil  # Added to track last leader heartbeat
      }

      defstruct [:election_timeout, :election_timer_ref, :last_leader_contact]
    end

    @min_timeout 150
    @max_timeout 300

    @impl true
    def init(_server_state) do
      {:ok, start_election_timer(%State{
        election_timeout: random_timeout(),
        last_leader_contact: System.monotonic_time(:millisecond)
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
          # Update term if needed - this automatically clears vote if term changes
          {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)
          # Record leader contact - this updates current_leader and last_leader_contact
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
            # Append new entries (this will handle truncating conflicting entries)
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

            # Reset election timer and update last contact time
            new_follower_state = reset_election_timer(follower_state)
            new_follower_state = %{new_follower_state |
              last_leader_contact: System.monotonic_time(:millisecond)
            }

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
          # Update term if needed - this automatically clears vote if term changes
          {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)

          # Check if candidate's log is at least as up-to-date as ours
          last_log_index = ServerState.get_last_log_index(updated_state)
          last_log_term = ServerState.get_last_log_term(updated_state)

          log_ok = (message.last_log_term > last_log_term) or
                   (message.last_log_term == last_log_term and
                    message.last_log_index >= last_log_index)

          grant_vote? = can_grant_vote?(updated_state, message.candidate_id) and log_ok

          if grant_vote? do
            case ServerState.record_vote_for(updated_state, message.candidate_id, message.term) do
              {:ok, voted_state} ->
                # Reset election timer when granting vote
                new_follower_state = reset_election_timer(follower_state)

                response = RequestVoteResponse.new(
                  voted_state.current_term,
                  true,
                  voted_state.node_id
                )
                {:ok, voted_state, new_follower_state, response}

              {:error, _} ->
                response = RequestVoteResponse.new(
                  updated_state.current_term,
                  false,
                  updated_state.node_id
                )
                {:ok, updated_state, follower_state, response}
            end
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
