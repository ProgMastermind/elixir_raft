defmodule ElixirRaft.Server.Follower do
  @moduledoc """
  Implementation of the Follower role in Raft.
  Followers:
  - Respond to AppendEntries from leaders
  - Respond to RequestVote from candidates
  - Convert to candidate if election timeout occurs
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  require Logger
  alias ElixirRaft.Core.{ServerState, Term, NodeId}
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
      last_heartbeat: integer() | nil
    }

    defstruct [
      :election_timeout,
      :election_timer_ref,
      :last_heartbeat
    ]
  end

  @min_timeout 150
  @max_timeout 300

  #
  # Role Behaviour Implementation
  #

  @impl true
  def init(_server_state) do
    state = %State{
      election_timeout: random_timeout(),
      last_heartbeat: now()
    }
    {:ok, start_election_timer(state)}
  end

  @impl true
  def handle_append_entries(message, server_state, follower_state) do
    case validate_append_entries(message, server_state) do
      :ok ->
        # Valid append entries from current leader
        {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)
        {:ok, with_leader} = ServerState.record_leader_contact(updated_state, message.leader_id)

        # Check log consistency
        case verify_log_consistency(message, with_leader) do
          :ok ->
            # Process entries and update state
            case apply_append_entries(message, with_leader) do
              {:ok, final_state} ->
                new_follower_state = reset_election_timer(follower_state)
                response = build_success_response(final_state, message)
                {:ok, final_state, new_follower_state, response}

              {:error, _reason} ->
                response = build_failure_response(with_leader)
                {:ok, with_leader, follower_state, response}
            end

          {:error, _reason} ->
            response = build_failure_response(with_leader)
            {:ok, with_leader, follower_state, response}
        end

      {:error, :old_term} ->
        # Reject messages from old terms
        response = build_failure_response(server_state)
        {:ok, server_state, follower_state, response}
    end
  end

  @impl true
  def handle_request_vote(message, server_state, follower_state) do
    case validate_vote_request(message, server_state) do
      :ok ->
        # Valid vote request
        {:ok, updated_state} = ServerState.maybe_update_term(server_state, message.term)
        {:ok, voted_state} = ServerState.record_vote_for(updated_state, message.candidate_id, message.term)

        new_follower_state = reset_election_timer(follower_state)
        response = RequestVoteResponse.new(voted_state.current_term, true, voted_state.node_id)

        {:ok, voted_state, new_follower_state, response}

      {:error, _reason} ->
        # Reject vote request
        response = RequestVoteResponse.new(server_state.current_term, false, server_state.node_id)
        {:ok, server_state, follower_state, response}
    end
  end

  @impl true
  def handle_append_entries_response(_message, server_state, follower_state) do
    # Followers don't handle append entries responses
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_request_vote_response(_message, server_state, follower_state) do
    # Followers don't handle vote responses
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_timeout(:election, server_state, _follower_state) do
    # Election timeout - convert to candidate
    {:transition, :candidate, server_state}
  end

  def handle_timeout(_type, server_state, follower_state) do
    # Ignore other timeout types
    {:ok, server_state, follower_state}
  end

  @impl true
  def handle_client_command(_command, server_state, _follower_state) do
    case server_state.current_leader do
      nil -> {:error, :no_leader}
      leader_id -> {:redirect, leader_id}
    end
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

  defp verify_log_consistency(%AppendEntries{} = message, server_state) do
    case message.prev_log_index do
      0 -> :ok
      _ ->
        case ServerState.get_log_entry(server_state, message.prev_log_index) do
          {:ok, entry} ->
            if entry.term == message.prev_log_term, do: :ok, else: {:error, :term_mismatch}
          {:error, :not_found} ->
            {:error, :missing_entry}
        end
    end
  end

  defp apply_append_entries(message, server_state) do
    with {:ok, with_entries} <- ServerState.append_entries(
           server_state,
           message.prev_log_index,
           message.entries
         ),
         {:ok, final_state} <- ServerState.update_commit_index(
           with_entries,
           min(message.leader_commit, message.prev_log_index + length(message.entries))
         ) do
      {:ok, final_state}
    end
  end

  defp build_success_response(server_state, message) do
    AppendEntriesResponse.new(
      server_state.current_term,
      true,
      server_state.node_id,
      message.prev_log_index + length(message.entries)
    )
  end

  defp build_failure_response(server_state) do
    AppendEntriesResponse.new(
      server_state.current_term,
      false,
      server_state.node_id,
      0
    )
  end

  defp validate_vote_request(message, server_state) do
    cond do
      Term.compare(message.term, server_state.current_term) == :lt ->
        {:error, :old_term}

      server_state.voted_for != nil &&
      server_state.voted_for != message.candidate_id ->
        {:error, :already_voted}

      not is_log_up_to_date?(message, server_state) ->
        {:error, :log_not_up_to_date}

      true ->
        :ok
    end
  end

  defp is_log_up_to_date?(message, server_state) do
    last_log_index = ServerState.get_last_log_index(server_state)
    last_log_term = ServerState.get_last_log_term(server_state)

    cond do
      message.last_log_term > last_log_term -> true
      message.last_log_term < last_log_term -> false
      message.last_log_index >= last_log_index -> true
      true -> false
    end
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
    start_election_timer(%{state |
      election_timeout: random_timeout(),
      last_heartbeat: now()
    })
  end

  defp now, do: System.monotonic_time(:millisecond)
end
