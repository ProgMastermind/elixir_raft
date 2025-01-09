defmodule ElixirRaft.Server.FollowerTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Server.Follower
  alias ElixirRaft.Core.{ServerState, NodeId, LogEntry}
  alias ElixirRaft.RPC.Messages.{AppendEntries, RequestVote}

  setup do
    node_id = NodeId.generate()
    server_state = ServerState.new(node_id)
    {:ok, follower_state} = Follower.init(server_state)

    {:ok, %{
      node_id: node_id,
      server_state: server_state,
      follower_state: follower_state
    }}
  end

  describe "initialization" do
    test "starts with election timer", %{follower_state: state} do
      assert state.election_timer_ref != nil
      assert state.election_timeout >= 150 && state.election_timeout <= 300
      assert state.last_heartbeat != nil
    end

    test "creates different timeouts for different initializations" do
      node_id = NodeId.generate()
      server_state = ServerState.new(node_id)
      {:ok, state1} = Follower.init(server_state)
      {:ok, state2} = Follower.init(server_state)

      assert state1.election_timeout != state2.election_timeout
    end
  end

  describe "handle_append_entries" do
    test "rejects append entries with lower term", context do
      leader_id = NodeId.generate()
      lower_term = context.server_state.current_term - 1

      message = AppendEntries.new(
        lower_term,
        leader_id,
        0,
        0,
        [],
        0
      )

      {:ok, state, _follower_state, response} =
        Follower.handle_append_entries(message, context.server_state, context.follower_state)

      assert response.success == false
      assert state.current_term == context.server_state.current_term
      assert response.match_index == 0
    end

    test "accepts append entries from current term leader", context do
      leader_id = NodeId.generate()
      message = AppendEntries.new(
        context.server_state.current_term,
        leader_id,
        0,
        0,
        [],
        0
      )

      {:ok, new_state, new_follower_state, response} =
        Follower.handle_append_entries(message, context.server_state, context.follower_state)

      assert response.success == true
      assert new_state.current_leader == leader_id
      assert new_follower_state.election_timer_ref != context.follower_state.election_timer_ref
    end

    test "handles conflicting entries correctly", context do
      # Add some entries to the log
      entry1 = %LogEntry{term: 1, index: 1, command: "cmd1"}
      entry2 = %LogEntry{term: 1, index: 2, command: "cmd2"}
      {:ok, state_with_entries} = ServerState.append_entries(
        context.server_state,
        0,
        [entry1, entry2]
      )

      # Leader sends conflicting entry for index 2
      leader_id = NodeId.generate()
      conflicting_entry = %LogEntry{term: 2, index: 2, command: "new_cmd"}
      message = AppendEntries.new(
        2,  # Higher term
        leader_id,
        1,  # prev_log_index
        1,  # prev_log_term
        [conflicting_entry],
        1
      )

      {:ok, final_state, _follower_state, response} =
        Follower.handle_append_entries(message, state_with_entries, context.follower_state)

      assert response.success == true
      {:ok, entry} = ServerState.get_log_entry(final_state, 2)
      assert entry.command == "new_cmd"
      assert entry.term == 2
    end

    test "verifies log consistency", context do
      # Create a message with prev_log_index that doesn't exist
      leader_id = NodeId.generate()
      message = AppendEntries.new(
        context.server_state.current_term,
        leader_id,
        1,  # prev_log_index that doesn't exist
        1,  # prev_log_term
        [],
        0
      )

      {:ok, _state, _follower_state, response} =
        Follower.handle_append_entries(message, context.server_state, context.follower_state)

      assert response.success == false
    end
  end

  describe "handle_request_vote" do
    test "grants vote when not voted in current term", context do
      candidate_id = NodeId.generate()
      message = RequestVote.new(
        context.server_state.current_term,
        candidate_id,
        0,
        0
      )

      {:ok, new_state, _follower_state, response} =
        Follower.handle_request_vote(message, context.server_state, context.follower_state)

      assert response.vote_granted == true
      assert new_state.voted_for == candidate_id
    end

    test "rejects vote when already voted in current term", context do
      # First vote
      candidate1_id = NodeId.generate()
      {:ok, voted_state} = ServerState.record_vote_for(
        context.server_state,
        candidate1_id,
        context.server_state.current_term
      )

      # Second vote attempt
      candidate2_id = NodeId.generate()
      message = RequestVote.new(
        context.server_state.current_term,
        candidate2_id,
        0,
        0
      )

      {:ok, _final_state, _follower_state, response} =
        Follower.handle_request_vote(message, voted_state, context.follower_state)

      assert response.vote_granted == false
    end

    test "checks log up-to-date requirement before granting vote", context do
      # Add some entries to follower's log
      entry1 = %LogEntry{term: 2, index: 1, command: "cmd1"}
      entry2 = %LogEntry{term: 2, index: 2, command: "cmd2"}
      {:ok, state_with_entries} = ServerState.append_entries(
        context.server_state,
        0,
        [entry1, entry2]
      )

      # Candidate with older/shorter log requests vote
      candidate_id = NodeId.generate()
      message = RequestVote.new(
        state_with_entries.current_term,
        candidate_id,
        1,  # last_log_index
        1   # last_log_term
      )

      {:ok, _final_state, _follower_state, response} =
        Follower.handle_request_vote(message, state_with_entries, context.follower_state)

      assert response.vote_granted == false
    end
  end

  describe "handle_timeout" do
    test "transitions to candidate on election timeout", context do
      {:transition, :candidate, server_state} =
        Follower.handle_timeout(:election, context.server_state, context.follower_state)

      assert server_state == context.server_state
    end

    test "ignores non-election timeouts", context do
      {:ok, server_state, follower_state} =
        Follower.handle_timeout(:unknown, context.server_state, context.follower_state)

      assert server_state == context.server_state
      assert follower_state == context.follower_state
    end
  end

  describe "handle_client_command" do
    test "returns no leader error when leader is unknown", context do
      assert {:error, :no_leader} ==
        Follower.handle_client_command("command", context.server_state, context.follower_state)
    end

    test "redirects to leader when leader is known", context do
      leader_id = NodeId.generate()
      state_with_leader = %{context.server_state | current_leader: leader_id}

      assert {:redirect, ^leader_id} =
        Follower.handle_client_command("command", state_with_leader, context.follower_state)
    end
  end
end
