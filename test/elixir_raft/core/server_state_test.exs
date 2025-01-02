defmodule ElixirRaft.Core.ServerStateTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Core.{ServerState, NodeId, LogEntry}

  describe "initialization" do
    test "new/1 creates initial server state" do
      node_id = NodeId.generate()
      state = ServerState.new(node_id)

      assert state.node_id == node_id
      assert state.current_term == 0
      assert state.role == :follower
      assert state.voted_for == nil
      assert state.current_leader == nil
      assert state.vote_state == nil
      assert state.last_leader_contact == nil
      assert state.log == []
      assert state.commit_index == 0
    end
  end

  describe "term management" do
    setup do
      {:ok, state: ServerState.new(NodeId.generate())}
    end

    test "maybe_update_term updates term and resets to follower", %{state: state} do
      {:ok, updated_state} = ServerState.maybe_update_term(state, 5)

      assert updated_state.current_term == 5
      assert updated_state.role == :follower
      assert updated_state.voted_for == nil
      assert updated_state.current_leader == nil
      assert updated_state.vote_state == nil
    end

    test "maybe_update_term ignores lower terms", %{state: state} do
      {:ok, state_with_term} = ServerState.maybe_update_term(state, 5)
      {:ok, final_state} = ServerState.maybe_update_term(state_with_term, 3)

      assert final_state == state_with_term
    end

    test "maybe_update_term keeps same term state", %{state: state} do
      {:ok, state_with_term} = ServerState.maybe_update_term(state, 5)
      {:ok, final_state} = ServerState.maybe_update_term(state_with_term, 5)

      assert final_state == state_with_term
    end
  end

  describe "log management" do
    setup do
          node_id = NodeId.generate()
          state = ServerState.new(node_id)

          {:ok, entry1} = LogEntry.new(1, 1, "cmd1")
          {:ok, entry2} = LogEntry.new(2, 1, "cmd2")
          {:ok, entry3} = LogEntry.new(3, 2, "cmd3")
          entries = [entry1, entry2, entry3]

          {:ok, state_with_log} = ServerState.append_entries(state, 0, entries)

          {:ok, %{
            empty_state: state,
            state: state_with_log,
            entries: entries
          }}
        end

      test "get_log_entry returns correct entry", %{state: state} do
        {:ok, entry} = ServerState.get_log_entry(state, 2)
        assert entry.command == "cmd2"
        assert entry.term == 1
      end

      test "get_log_entry returns error for non-existent entry", %{state: state} do
        assert {:error, :not_found} = ServerState.get_log_entry(state, 99)
      end

      test "get_last_log_entry returns latest entry", %{state: state} do
        {:ok, entry} = ServerState.get_last_log_entry(state)
        assert entry.command == "cmd3"
        assert entry.term == 2
      end

      test "get_last_log_entry returns error for empty log", %{empty_state: state} do
        assert {:error, :not_found} = ServerState.get_last_log_entry(state)
      end

      test "get_last_log_term returns correct term", %{state: state} do
        last_term = ServerState.get_last_log_term(state)
        assert last_term == 2
      end

      test "get_last_log_term returns 0 for empty log", %{empty_state: state} do
        assert ServerState.get_last_log_term(state) == 0
      end

      test "get_last_log_index returns correct index", %{state: state} do
        assert ServerState.get_last_log_index(state) == 3
      end

      test "get_last_log_index returns 0 for empty log", %{empty_state: state} do
        assert ServerState.get_last_log_index(state) == 0
      end

      test "append_entries adds entries correctly", %{empty_state: state} do
            {:ok, new_entry} = LogEntry.new(1, 1, "new_cmd")
            entries = [new_entry]
            {:ok, new_state} = ServerState.append_entries(state, 0, entries)

            assert length(new_state.log) == 1
            {:ok, entry} = ServerState.get_log_entry(new_state, 1)
            assert entry.command == "new_cmd"
          end

          test "append_entries truncates conflicting entries", %{state: state} do
            # Add conflicting entry at index 2
            {:ok, conflict_entry} = LogEntry.new(2, 2, "conflict")
            new_entries = [conflict_entry]
            {:ok, new_state} = ServerState.append_entries(state, 1, new_entries)

            assert length(new_state.log) == 2
            {:ok, entry} = ServerState.get_log_entry(new_state, 2)
            assert entry.command == "conflict"
            assert entry.term == 2
          end

          test "append_entries validates prev_log_index", %{state: state} do
            {:ok, new_entry} = LogEntry.new(100, 1, "cmd")
            result = ServerState.append_entries(state, 99, [new_entry])
            assert {:error, _} = result
          end
  end

  describe "commit index management" do
    setup do
      state = ServerState.new(NodeId.generate())
      entries = [
        LogEntry.new(1, 1, "cmd1"),
        LogEntry.new(2, 1, "cmd2")
      ]
      {:ok, state_with_log} = ServerState.append_entries(state, 0, entries)
      {:ok, %{state: state_with_log}}
    end

    test "update_commit_index updates to valid index", %{state: state} do
      {:ok, updated_state} = ServerState.update_commit_index(state, 1)
      assert updated_state.commit_index == 1
    end

    test "update_commit_index rejects index beyond log", %{state: state} do
      result = ServerState.update_commit_index(state, 99)
      assert {:error, _} = result
    end

    test "update_commit_index rejects lower index", %{state: state} do
      {:ok, state_with_commit} = ServerState.update_commit_index(state, 2)
      result = ServerState.update_commit_index(state_with_commit, 1)
      assert {:error, _} = result
    end
  end

  describe "vote management" do
    setup do
      {:ok, state: ServerState.new(NodeId.generate())}
    end

    test "record_vote_for records valid vote", %{state: state} do
      candidate_id = NodeId.generate()
      {:ok, voted_state} = ServerState.record_vote_for(state, candidate_id, state.current_term)

      assert voted_state.voted_for == candidate_id
    end

    test "record_vote_for rejects vote for different term", %{state: state} do
      candidate_id = NodeId.generate()
      result = ServerState.record_vote_for(state, candidate_id, state.current_term + 1)

      assert {:error, _} = result
    end

    test "record_vote records vote received as candidate", %{state: state} do
      # Setup candidate state
      {:ok, candidate_state} = ServerState.maybe_update_term(state, 1)
      candidate_state = %{candidate_state |
        role: :candidate,
        vote_state: %{
          term: 1,
          votes_received: MapSet.new(),
          votes_granted: MapSet.new()
        }
      }

      voter_id = NodeId.generate()
      {:ok, updated_state} = ServerState.record_vote(candidate_state, voter_id, true)

      assert MapSet.member?(updated_state.vote_state.votes_received, voter_id)
      assert MapSet.member?(updated_state.vote_state.votes_granted, voter_id)
    end

    test "record_vote rejects vote for wrong term", %{state: state} do
      # Setup candidate state with different term
      {:ok, candidate_state} = ServerState.maybe_update_term(state, 2)
      candidate_state = %{candidate_state |
        role: :candidate,
        vote_state: %{
          term: 1, # Different from current_term
          votes_received: MapSet.new(),
          votes_granted: MapSet.new()
        }
      }

      result = ServerState.record_vote(candidate_state, NodeId.generate(), true)
      assert {:error, _} = result
    end
  end

  describe "leader management" do
    setup do
      {:ok, state: ServerState.new(NodeId.generate())}
    end

    test "record_leader_contact updates leader and timestamp", %{state: state} do
      leader_id = NodeId.generate()
      {:ok, updated_state} = ServerState.record_leader_contact(state, leader_id)

      assert updated_state.current_leader == leader_id
      assert is_integer(updated_state.last_leader_contact)
    end
  end
end
