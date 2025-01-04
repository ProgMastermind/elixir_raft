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
    {:ok, leader_state} = Leader.init(server_state)

    {:ok, %{
      node_id: node_id,
      server_state: server_state,
      leader_state: leader_state
    }}
  end

  describe "initialization" do
    test "initializes with proper state", %{leader_state: state} do
      assert state.heartbeat_timer_ref != nil
      assert state.heartbeat_timeout == 50
      assert is_map(state.next_index)
      assert is_map(state.match_index)
    end

    test "sets correct initial next_index", %{leader_state: state} do
      Enum.each(state.next_index, fn {_id, index} ->
        assert index == 1  # log starts empty, so next_index is 1
      end)
    end

    test "sets correct initial match_index", %{leader_state: state} do
      Enum.each(state.match_index, fn {_id, index} ->
        assert index == 0  # match_index starts at 0
      end)
    end
  end

  describe "append entries handling" do
    test "rejects append entries from old term", context do
      message = AppendEntries.new(
        context.server_state.current_term - 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:ok, _state, _leader_state, response} =
        Leader.handle_append_entries(message, context.server_state, context.leader_state)

      assert response.success == false
      assert response.term == context.server_state.current_term
    end

    test "steps down on higher term append entries", context do
      message = AppendEntries.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:transition, :follower, _state, _leader_state} =
        Leader.handle_append_entries(message, context.server_state, context.leader_state)
    end
  end

  describe "append entries response handling" do
    test "updates progress on successful response", context do
      follower_id = "node_2"
      message = AppendEntriesResponse.new(
        context.server_state.current_term,
        true,
        follower_id,
        1
      )

      {:ok, _server_state, new_leader_state} =
        Leader.handle_append_entries_response(message, context.server_state, context.leader_state)

      assert new_leader_state.match_index[follower_id] == 1
      assert new_leader_state.next_index[follower_id] == 2
    end

    test "decrements next_index on failed response", context do
          follower_id = "node_2"
          # Set initial next_index to 2
          leader_state = %{context.leader_state |
            next_index: Map.put(context.leader_state.next_index, follower_id, 2)
          }

          message = AppendEntriesResponse.new(
            context.server_state.current_term,
            false,
            follower_id,
            0
          )

          {:ok, _server_state, new_leader_state} =
            Leader.handle_append_entries_response(message, context.server_state, leader_state)

          assert new_leader_state.next_index[follower_id] == 1
        end

    test "steps down on higher term response", context do
      message = AppendEntriesResponse.new(
        context.server_state.current_term + 1,
        false,
        "node_2",
        0
      )

      {:transition, :follower, _state, _leader_state} =
        Leader.handle_append_entries_response(message, context.server_state, context.leader_state)
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

      {:ok, _state, _leader_state, response} =
        Leader.handle_request_vote(message, context.server_state, context.leader_state)

      assert response.vote_granted == false
    end

    test "steps down on higher term vote request", context do
      message = RequestVote.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0
      )

      {:transition, :follower, _state, _leader_state} =
        Leader.handle_request_vote(message, context.server_state, context.leader_state)
    end
  end

  describe "request vote response handling" do
    test "steps down on higher term response", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term + 1,
        false,
        NodeId.generate()
      )

      {:transition, :follower, _state, _leader_state} =
        Leader.handle_request_vote_response(message, context.server_state, context.leader_state)
    end

    test "ignores vote responses from current term", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term,
        true,
        NodeId.generate()
      )

      {:ok, state, leader_state} =
        Leader.handle_request_vote_response(message, context.server_state, context.leader_state)

      assert state == context.server_state
      assert leader_state == context.leader_state
    end
  end

  describe "timeout handling" do
    test "resets heartbeat timer on timeout", context do
      {:ok, _state, new_leader_state} =
        Leader.handle_timeout(:heartbeat, context.server_state, context.leader_state)

      assert new_leader_state.heartbeat_timer_ref != context.leader_state.heartbeat_timer_ref
    end

    test "ignores non-heartbeat timeouts", context do
      {:ok, state, leader_state} =
        Leader.handle_timeout(:unknown, context.server_state, context.leader_state)

      assert state == context.server_state
      assert leader_state == context.leader_state
    end
  end

  describe "client command handling" do
    test "appends new entry to log", context do
      {:ok, new_server_state, _leader_state} =
        Leader.handle_client_command("test_command", context.server_state, context.leader_state)

      assert length(new_server_state.log) == 1
      [entry] = new_server_state.log
      assert entry.command == "test_command"
      assert entry.term == context.server_state.current_term
    end
  end

  describe "commit index advancement" do
    test "advances commit index with majority replication", context do
          # Add an entry to the log
          {:ok, entry} = LogEntry.new(1, context.server_state.current_term, "test")
          {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [entry])

          # Simulate successful replication to a majority
          message1 = AppendEntriesResponse.new(
            server_state.current_term,
            true,
            "node_2",
            1
          )

          message2 = AppendEntriesResponse.new(
            server_state.current_term,
            true,
            "node_3",
            1
          )

          # Update progress for both followers
          {:ok, server_state1, leader_state1} =
            Leader.handle_append_entries_response(message1, server_state, context.leader_state)

          {:ok, final_server_state, _leader_state} =
            Leader.handle_append_entries_response(message2, server_state1, leader_state1)

          assert final_server_state.commit_index == 1
        end

    test "doesn't advance commit index without majority", context do
      # Add an entry to the log
      {:ok, entry} = LogEntry.new(1, context.server_state.current_term, "test")
      {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [entry])

      # Simulate successful replication to only one follower (not majority)
      message = AppendEntriesResponse.new(
        server_state.current_term,
        true,
        "node_2",
        1
      )

      {:ok, final_server_state, _leader_state} =
        Leader.handle_append_entries_response(message, server_state, context.leader_state)

      assert final_server_state.commit_index == 0
    end
  end

  describe "log replication" do
      test "replicates single entry at a time", context do
        # Add two entries to the log
        {:ok, entry1} = LogEntry.new(1, context.server_state.current_term, "test1")
        {:ok, entry2} = LogEntry.new(2, context.server_state.current_term, "test2")
        {:ok, server_state} = ServerState.append_entries(context.server_state, 0, [entry1, entry2])

        follower_id = "node_2"
        # Simulate first successful replication
        message1 = AppendEntriesResponse.new(
          server_state.current_term,
          true,
          follower_id,
          1
        )

        {:ok, _server_state1, leader_state1} =
          Leader.handle_append_entries_response(message1, server_state, context.leader_state)

        # Verify next_index was updated correctly
        assert leader_state1.next_index[follower_id] == 2
        assert leader_state1.match_index[follower_id] == 1
      end

      test "handles repeated failures by decrementing next_index", context do
        follower_id = "node_2"
        # Set initial next_index to 3
        leader_state = %{context.leader_state |
          next_index: Map.put(context.leader_state.next_index, follower_id, 3)
        }

        # Simulate three consecutive failures
        message = AppendEntriesResponse.new(
          context.server_state.current_term,
          false,
          follower_id,
          0
        )

        {:ok, _, leader_state1} =
          Leader.handle_append_entries_response(message, context.server_state, leader_state)
        {:ok, _, leader_state2} =
          Leader.handle_append_entries_response(message, context.server_state, leader_state1)

        # Verify next_index was decremented properly
        assert leader_state2.next_index[follower_id] == 1
      end
    end

    describe "commit index safety" do
      test "only commits entries from current term", context do
        # Add entry from previous term
        {:ok, old_entry} = LogEntry.new(1, context.server_state.current_term - 1, "old")
        {:ok, server_state1} = ServerState.append_entries(context.server_state, 0, [old_entry])

        # Add entry from current term
        {:ok, new_entry} = LogEntry.new(2, context.server_state.current_term, "new")
        {:ok, server_state2} = ServerState.append_entries(server_state1, 1, [new_entry])

        # Simulate majority replication of both entries
        message1 = AppendEntriesResponse.new(
          server_state1.current_term,
          true,
          "node_2",
          2
        )
        message2 = AppendEntriesResponse.new(
          server_state2.current_term,
          true,
          "node_3",
          2
        )

        {:ok, server_state3, leader_state1} =
          Leader.handle_append_entries_response(message1, server_state2, context.leader_state)
        {:ok, final_server_state, _} =
          Leader.handle_append_entries_response(message2, server_state3, leader_state1)

        # Should only commit up to the latest entry from current term
        assert final_server_state.commit_index == 2
      end
    end
end
