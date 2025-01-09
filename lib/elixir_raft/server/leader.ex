defmodule ElixirRaft.Server.Leader do
  @moduledoc """
  Implementation of the Leader role in Raft.
  Leaders:
  - Send periodic heartbeats
  - Manage log replication
  - Track follower progress
  - Handle client requests
  - Step down when discovering higher term
  """

  @behaviour ElixirRaft.Server.RoleBehaviour

  require Logger
  alias ElixirRaft.Core.{ServerState, Term, NodeId, ClusterInfo, LogEntry}
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    AppendEntriesResponse,
    RequestVote,
    RequestVoteResponse
  }

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
      next_index: %{NodeId.t() => non_neg_integer()},
      match_index: %{NodeId.t() => non_neg_integer()},
      heartbeat_timer_ref: reference() | nil,
      heartbeat_interval: pos_integer()
    }

    defstruct [
      :heartbeat_timer_ref,
      :heartbeat_interval,
      next_index: %{},
      match_index: %{}
    ]
  end

  @heartbeat_interval 50  # milliseconds

  #
  # Role Behaviour Implementation
  #

  @impl true
  def init(server_state) do
    # Initialize leader state
    state = initialize_leader_state(server_state)

    # Create initial heartbeat message
    heartbeat = create_heartbeat(server_state)

    # Start heartbeat timer and broadcast initial heartbeat
    {:ok, server_state, start_heartbeat_timer(state), {:broadcast, heartbeat}}
  end

  @impl true
  def handle_append_entries(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down if we see higher term
        Logger.info("Stepping down: received AppendEntries with higher term",
          current_term: server_state.current_term,
          new_term: message.term
        )
        {:transition, :follower, server_state}

      _ ->
        # Reject messages from old/same term (there can't be another leader in our term)
        response = AppendEntriesResponse.new(
          server_state.current_term,
          false,
          server_state.node_id,
          0
        )
        {:ok, server_state, leader_state, response}
    end
  end

  @impl true
  def handle_append_entries_response(message, server_state, leader_state) do
    case validate_append_response(message, server_state) do
      :ok when message.success ->
        # Update follower progress
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

      :ok ->
        # Decrement nextIndex for follower and retry replication immediately
        new_leader_state = decrement_next_index(
          leader_state,
          message.follower_id
        )
        append_entries = create_append_entries(server_state, message.follower_id, new_leader_state)
        {:ok, server_state, new_leader_state, {:send, message.follower_id, append_entries}}

      {:error, :higher_term} ->
        # Step down if we see higher term
        {:transition, :follower, server_state}
    end
  end

  @impl true
  def handle_request_vote(message, server_state, leader_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt ->
        # Step down if we see higher term
        Logger.info("Stepping down: received RequestVote with higher term",
          current_term: server_state.current_term,
          new_term: message.term
        )
        {:transition, :follower, server_state}

      _ ->
        # Reject vote request (we're the current leader)
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
        {:transition, :follower, server_state}
      _ ->
        # Ignore vote responses as leader
        {:ok, server_state, leader_state}
    end
  end

  @impl true
  def handle_timeout(:heartbeat, server_state, leader_state) do
    # Create and broadcast heartbeat/append entries to all followers
    messages = create_append_entries_for_all(server_state, leader_state)
    new_state = start_heartbeat_timer(leader_state)
    {:ok, server_state, new_state, {:broadcast_multiple, messages}}
  end

  def handle_timeout(_type, server_state, leader_state) do
    {:ok, server_state, leader_state}
  end

  @impl true
  def handle_client_command(command, server_state, leader_state) do
    # Append entry to local log
    last_index = ServerState.get_last_log_index(server_state)
    new_entry = LogEntry.new!(
      last_index + 1,
      server_state.current_term,
      command
    )

    case ServerState.append_entries(server_state, last_index, [new_entry]) do
      {:ok, new_server_state} ->
        # Immediately try to replicate to followers
        messages = create_append_entries_for_all(new_server_state, leader_state)
        {:ok, new_server_state, leader_state, {:broadcast_multiple, messages}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  #
  # Private Functions
  #

  defp initialize_leader_state(server_state) do
    last_log_index = ServerState.get_last_log_index(server_state)
    peers = ClusterInfo.get_peer_ids(server_state.node_id)

    next_index = Map.new(peers, fn peer -> {peer, last_log_index + 1} end)
    match_index = Map.new(peers, fn peer -> {peer, 0} end)

    %State{
      heartbeat_interval: @heartbeat_interval,
      next_index: next_index,
      match_index: match_index
    }
  end

  defp create_heartbeat(server_state) do
    AppendEntries.heartbeat(
      server_state.current_term,
      server_state.node_id,
      ServerState.get_last_log_index(server_state),
      ServerState.get_last_log_term(server_state),
      server_state.commit_index
    )
  end

  defp create_append_entries(server_state, follower_id, leader_state) do
    next_index = Map.get(leader_state.next_index, follower_id)
    prev_index = next_index - 1

    # Get previous log entry info
    prev_term = case ServerState.get_log_entry(server_state, prev_index) do
      {:ok, entry} -> entry.term
      _ -> 0
    end

    # Get entries to send
    entries = case ServerState.get_entries_from(server_state, next_index) do
      {:ok, entries} -> entries
      _ -> []
    end

    AppendEntries.new(
      server_state.current_term,
      server_state.node_id,
      prev_index,
      prev_term,
      entries,
      server_state.commit_index
    )
  end

  defp create_append_entries_for_all(server_state, leader_state) do
    peers = ClusterInfo.get_peer_ids(server_state.node_id)
    Enum.map(peers, fn peer_id ->
      {peer_id, create_append_entries(server_state, peer_id, leader_state)}
    end)
  end

  defp validate_append_response(message, server_state) do
    case Term.compare(message.term, server_state.current_term) do
      :gt -> {:error, :higher_term}
      _ -> :ok
    end
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
    match_indexes = Map.values(leader_state.match_index)
    sorted_indexes = Enum.sort(match_indexes, :desc)
    majority_size = ClusterInfo.majority_size()

    case find_majority_index(sorted_indexes, majority_size) do
      {:ok, index} when index > server_state.commit_index ->
        case verify_term_at_index(server_state, index) do
          {:ok, true} -> ServerState.update_commit_index(server_state, index)
          _ -> {:ok, server_state}
        end
      _ ->
        {:ok, server_state}
    end
  end

  defp find_majority_index(sorted_indexes, majority_size) do
    case Enum.find(sorted_indexes, fn index ->
      count = Enum.count(sorted_indexes, &(&1 >= index))
      count >= majority_size
    end) do
      nil -> {:error, :no_majority}
      index -> {:ok, index}
    end
  end

  defp verify_term_at_index(server_state, index) do
    case ServerState.get_log_entry(server_state, index) do
      {:ok, entry} -> {:ok, entry.term == server_state.current_term}
      error -> error
    end
  end

  defp start_heartbeat_timer(%State{} = state) do
    if state.heartbeat_timer_ref, do: Process.cancel_timer(state.heartbeat_timer_ref)
    timer_ref = Process.send_after(self(), {:timeout, :heartbeat}, state.heartbeat_interval)
    %{state | heartbeat_timer_ref: timer_ref}
  end
end
