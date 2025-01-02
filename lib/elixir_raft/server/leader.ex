defmodule ElixirRaft.Server.Leader do
  @moduledoc """
  Implementation of the Leader role in the Raft consensus protocol.

  Leader responsibilities:
  1. Handle client requests
  2. Manage log replication to followers
  3. Maintain commit index
  4. Send heartbeats
  5. Track follower progress
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  alias ElixirRaft.Core.{ServerState, Term, LogEntry}
  alias ElixirRaft.RPC.Messages.{
    AppendEntriesResponse,
    RequestVoteResponse,
  }

  defmodule State do
    @moduledoc false

    @type follower_progress :: %{
      next_index: pos_integer(),
      match_index: non_neg_integer()
    }

    @type t :: %__MODULE__{
      next_index: %{NodeId.t() => pos_integer()},
      match_index: %{NodeId.t() => non_neg_integer()},
      heartbeat_timer_ref: reference() | nil,
      heartbeat_timeout: pos_integer()
    }

    defstruct [
      :next_index,
      :match_index,
      :heartbeat_timer_ref,
      :heartbeat_timeout
    ]
  end

  @heartbeat_interval 50  # milliseconds

  @impl true
  def init(server_state) do
    # Initialize nextIndex for each follower to leader's last log index + 1
    last_log_index = ServerState.get_last_log_index(server_state)
    cluster_size = Application.get_env(:elixir_raft, :cluster_size, 3)

    # Initialize empty maps for next_index and match_index
    {next_index, match_index} = initialize_follower_progress(
      server_state.node_id,
      cluster_size,
      last_log_index + 1
    )

    state = %State{
      next_index: next_index,
      match_index: match_index,
      heartbeat_timeout: @heartbeat_interval
    }

    {:ok, start_heartbeat_timer(state)}
  end

  @impl true
  def handle_append_entries(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :lt ->
        # Reject old term messages
        response = AppendEntriesResponse.new(
          server_state.current_term,
          false,
          server_state.node_id,
          0
        )
        {:ok, server_state, leader_state, response}

      _ ->
        # Step down if we see equal or higher term
        {:transition, :follower, server_state, leader_state}
    end
  end

  @impl true
  def handle_append_entries_response(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down if we see higher term
        {:transition, :follower, server_state, leader_state}

      _ when message.success ->
        # Update follower progress on success
        new_leader_state = update_follower_progress(
          leader_state,
          message.follower_id,
          message.match_index
        )

        # Try to advance commit index
        case maybe_advance_commit_index(server_state, new_leader_state) do
          {:ok, new_server_state} ->
            {:ok, new_server_state, new_leader_state}
          {:error, _} ->
            {:ok, server_state, new_leader_state}
        end

      _ ->
        # Decrement nextIndex for follower on failure
        new_leader_state = decrement_next_index(
          leader_state,
          message.follower_id
        )
        {:ok, server_state, new_leader_state}
    end
  end

  @impl true
  def handle_request_vote(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down if we see higher term
        {:transition, :follower, server_state, leader_state}

      _ ->
        # Reject vote request as we're the current leader
        response = RequestVoteResponse.new(
          server_state.current_term,
          false,
          server_state.node_id
        )
        {:ok, server_state, leader_state, response}
    end
  end

  @impl true
  def handle_request_vote_response(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down if we see higher term
        {:transition, :follower, server_state, leader_state}
      _ ->
        # Ignore vote responses as leader
        {:ok, server_state, leader_state}
    end
  end

  @impl true
  def handle_timeout(:heartbeat, server_state, leader_state) do
    # Send heartbeats to all followers
    new_leader_state = start_heartbeat_timer(leader_state)
    {:ok, server_state, new_leader_state}
  end

  @impl true
  def handle_timeout(_other, server_state, leader_state) do
    {:ok, server_state, leader_state}
  end

  @impl true
  def handle_client_command(command, server_state, leader_state) do
    # Append entry to local log
    last_index = ServerState.get_last_log_index(server_state)
    {:ok, entry} = LogEntry.new(
      last_index + 1,
      server_state.current_term,
      command
    )

    case ServerState.append_entries(server_state, last_index, [entry]) do
      {:ok, new_server_state} ->
        {:ok, new_server_state, leader_state}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Functions

  defp initialize_follower_progress(leader_id, cluster_size, initial_next_index) do
    # Create a range of follower IDs excluding the leader
    follower_ids = for i <- 1..cluster_size,
                      node_id = "node_#{i}",
                      node_id != leader_id,
                      do: node_id

    next_index = Map.new(follower_ids, fn id -> {id, initial_next_index} end)
    match_index = Map.new(follower_ids, fn id -> {id, 0} end)

    {next_index, match_index}
  end

  defp update_follower_progress(leader_state, follower_id, match_index) do
    %{leader_state |
      match_index: Map.put(leader_state.match_index, follower_id, match_index),
      next_index: Map.put(leader_state.next_index, follower_id, match_index + 1)
    }
  end

  defp decrement_next_index(leader_state, follower_id) do
    current_next = Map.get(leader_state.next_index, follower_id)
    new_next = max(1, current_next - 1)
    %{leader_state |
      next_index: Map.put(leader_state.next_index, follower_id, new_next)
    }
  end

  defp maybe_advance_commit_index(server_state, leader_state) do
      # Find indexes that have been replicated to a majority
      match_indexes = Map.values(leader_state.match_index)
      sorted_indexes = Enum.sort(match_indexes, :desc)

      # Include leader's log in the count (leader always has the entry)
      majority_needed = div(length(Map.keys(leader_state.match_index)) + 1, 2) + 1

      # Get the highest index with majority replication
      case Enum.find(sorted_indexes, fn index ->
        count = Enum.count(match_indexes, &(&1 >= index)) + 1  # +1 for leader
        count >= majority_needed
      end) do
        nil ->
          {:ok, server_state}
        index when index > server_state.commit_index ->
          case ServerState.get_log_entry(server_state, index) do
            {:ok, entry} when entry.term == server_state.current_term ->
              ServerState.update_commit_index(server_state, index)
            _ ->
              {:ok, server_state}
          end
        _ ->
          {:ok, server_state}
      end
    end

  defp start_heartbeat_timer(%State{} = state) do
    if state.heartbeat_timer_ref, do: Process.cancel_timer(state.heartbeat_timer_ref)
    timer_ref = Process.send_after(self(), {:timeout, :heartbeat}, state.heartbeat_timeout)
    %{state | heartbeat_timer_ref: timer_ref}
  end
end
