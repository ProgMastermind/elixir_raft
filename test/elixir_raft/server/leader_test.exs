defmodule ElixirRaft.Server.LeaderTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Server.Leader
  alias ElixirRaft.Core.{ServerState, NodeId, LogEntry}
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    RequestVote,
    RequestVoteResponse,
    AppendEntriesResponse
  }

  setup do
    node_id = NodeId.generate()
    server_state = ServerState.new(node_id)
    # Set current term to 1 as leader must have won an election
    {:ok, server_state} = ServerState.maybe_update_term(server_state, 1)
    {:ok, server_state, leader_state, _broadcast} = Leader.init(server_state)

    {:ok, %{
      node_id: node_id,
      server_state: server_state,
      leader_state: leader_state
    }}
  end

  describe "initialization" do
    test "initializes with proper state", %{leader_state: state} do
      assert state.heartbeat_timer_ref != nil
      assert state.heartbeat_interval == 50
      assert is_map(state.next_index)
      assert is_map(state.match_index)
    end

    test "sets correct initial next_index", %{server_state: server_state, leader_state: state} do
      last_log_index = ServerState.get_last_log_index(server_state)
      Enum.each(state.next_index, fn {_id, index} ->
        assert index == last_log_index + 1
      end)
    end

    test "initializes match_index to zero", %{leader_state: state} do
      Enum.each(state.match_index, fn {_id, index} ->
        assert index == 0
      end)
    end

    test "broadcasts initial heartbeat on initialization", %{server_state: server_state} do
      {:ok, _server_state, _leader_state, {:broadcast, heartbeat}} = Leader.init(server_state)
      assert heartbeat.term == server_state.current_term
      assert heartbeat.leader_id == server_state.node_id
      assert length(heartbeat.entries) == 0
    end
  end

  describe "log replication" do
    test "handles successful append entries response with log catch-up", context do
      follower_id = NodeId.generate()
      entry1 = LogEntry.new!(1, context.server_state.current_term, "cmd1")
      entry2 = LogEntry.new!(2, context.server_state.current_term, "cmd2")
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [entry1, entry2])

      leader_state = %{context.leader_state |
        next_index: Map.put(context.leader_state.next_index, follower_id, 1),
        match_index: Map.put(context.leader_state.match_index, follower_id, 0)
      }

      message = AppendEntriesResponse.new(
        server_state.current_term,
        true,
        follower_id,
        2  # Caught up to index 2
      )

      {:ok, _server_state, new_leader_state} =
        Leader.handle_append_entries_response(message, server_state, leader_state)

      assert new_leader_state.next_index[follower_id] == 3
      assert new_leader_state.match_index[follower_id] == 2
    end

    test "handles failed append entries with log consistency check", context do
      follower_id = NodeId.generate()
      entries = [
        LogEntry.new!(1, context.server_state.current_term, "cmd1"),
        LogEntry.new!(2, context.server_state.current_term, "cmd2"),
        LogEntry.new!(3, context.server_state.current_term, "cmd3")
      ]
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, entries)

      leader_state = %{context.leader_state |
        next_index: Map.put(context.leader_state.next_index, follower_id, 4)
      }

      message = AppendEntriesResponse.new(
        server_state.current_term,
        false,
        follower_id,
        0
      )

      {:ok, _server_state, new_leader_state, {:send, ^follower_id, retry_message}} =
        Leader.handle_append_entries_response(message, server_state, leader_state)

      assert new_leader_state.next_index[follower_id] == 3
      assert retry_message.prev_log_index == 2
    end

    test "handles client command by appending to log", context do
      command = "test_command"
      {:ok, new_server_state, _leader_state, {:broadcast_multiple, messages}} =
        Leader.handle_client_command(command, context.server_state, context.leader_state)

      assert ServerState.get_last_log_index(new_server_state) == 1
      {:ok, last_entry} = ServerState.get_last_log_entry(new_server_state)
      assert last_entry.command == command
      assert last_entry.term == context.server_state.current_term
      assert length(messages) > 0
    end
  end

  describe "commit index advancement" do
    test "advances commit index with majority replication of current term entries", context do
      entries = [
        LogEntry.new!(1, context.server_state.current_term, "cmd1"),
        LogEntry.new!(2, context.server_state.current_term, "cmd2")
      ]
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, entries)

      follower_responses = [
        AppendEntriesResponse.new(server_state.current_term, true, NodeId.generate(), 2),
        AppendEntriesResponse.new(server_state.current_term, true, NodeId.generate(), 2)
      ]

      final_state = Enum.reduce(follower_responses, {server_state, context.leader_state},
        fn response, {curr_server_state, curr_leader_state} ->
          {:ok, new_server_state, new_leader_state} =
            Leader.handle_append_entries_response(response, curr_server_state, curr_leader_state)
          {new_server_state, new_leader_state}
        end)

      assert (elem(final_state, 0)).commit_index == 2
    end

    test "doesn't advance commit index for entries from previous term", context do
      old_entry = LogEntry.new!(1, context.server_state.current_term - 1, "old")
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [old_entry])

      follower_responses = [
        AppendEntriesResponse.new(server_state.current_term, true, NodeId.generate(), 1),
        AppendEntriesResponse.new(server_state.current_term, true, NodeId.generate(), 1)
      ]

      final_state = Enum.reduce(follower_responses, {server_state, context.leader_state},
        fn response, {curr_server_state, curr_leader_state} ->
          {:ok, new_server_state, new_leader_state} =
            Leader.handle_append_entries_response(response, curr_server_state, curr_leader_state)
          {new_server_state, new_leader_state}
        end)

      assert (elem(final_state, 0)).commit_index == 0
    end

    test "doesn't advance commit index without majority", context do
      entry = LogEntry.new!(1, context.server_state.current_term, "cmd1")
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [entry])

      response = AppendEntriesResponse.new(
        server_state.current_term,
        true,
        NodeId.generate(),
        1
      )

      {:ok, new_server_state, _new_leader_state} =
        Leader.handle_append_entries_response(response, server_state, context.leader_state)

      assert new_server_state.commit_index == 0
    end
  end

  describe "leader step down" do
    test "steps down when receiving higher term in append entries", context do
      message = AppendEntries.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:transition, :follower, new_state} =
        Leader.handle_append_entries(message, context.server_state, context.leader_state)

      assert new_state.current_term == context.server_state.current_term
    end

    test "steps down when receiving higher term in append response", context do
      message = AppendEntriesResponse.new(
        context.server_state.current_term + 1,
        false,
        NodeId.generate(),
        0
      )

      {:transition, :follower, new_state} =
        Leader.handle_append_entries_response(message, context.server_state, context.leader_state)

      assert new_state.current_term == context.server_state.current_term
    end

    test "steps down when receiving higher term in request vote", context do
      message = RequestVote.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0
      )

      {:transition, :follower, new_state} =
        Leader.handle_request_vote(message, context.server_state, context.leader_state)

      assert new_state.current_term == context.server_state.current_term
    end
  end

  describe "request vote handling" do
    test "rejects vote requests from same term", context do
      message = RequestVote.new(
        context.server_state.current_term,
        NodeId.generate(),
        0,
        0
      )

      {:ok, _server_state, _leader_state, response} =
        Leader.handle_request_vote(message, context.server_state, context.leader_state)

      assert response.term == context.server_state.current_term
      refute response.vote_granted
    end

    test "ignores vote responses", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term,
        true,
        NodeId.generate()
      )

      {:ok, server_state, leader_state} =
        Leader.handle_request_vote_response(message, context.server_state, context.leader_state)

      assert server_state == context.server_state
      assert leader_state == context.leader_state
    end
  end

  describe "heartbeat mechanism" do
    test "sends periodic heartbeats with current commit index", context do
      {:ok, _state, new_leader_state, {:broadcast_multiple, messages}} =
        Leader.handle_timeout(:heartbeat, context.server_state, context.leader_state)

      assert new_leader_state.heartbeat_timer_ref != context.leader_state.heartbeat_timer_ref

      Enum.each(messages, fn {_node_id, message} ->
        assert message.term == context.server_state.current_term
        assert message.leader_id == context.server_state.node_id
        assert message.leader_commit == context.server_state.commit_index
      end)
    end

    test "restarts heartbeat timer after timeout", context do
      {:ok, _state, new_leader_state, _broadcast} =
        Leader.handle_timeout(:heartbeat, context.server_state, context.leader_state)

      assert new_leader_state.heartbeat_timer_ref != nil
      assert new_leader_state.heartbeat_timer_ref != context.leader_state.heartbeat_timer_ref
    end

    test "ignores non-heartbeat timeouts", context do
      {:ok, server_state, leader_state} =
        Leader.handle_timeout(:unknown, context.server_state, context.leader_state)

      assert server_state == context.server_state
      assert leader_state == context.leader_state
    end
  end
end
