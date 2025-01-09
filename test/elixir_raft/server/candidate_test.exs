defmodule ElixirRaft.Server.CandidateTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Server.Candidate
  alias ElixirRaft.Core.{ServerState, Term, NodeId, ClusterInfo}
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    AppendEntriesResponse,
    RequestVote,
    RequestVoteResponse
  }

  setup do
    node_id = NodeId.generate()
    server_state = ServerState.new(node_id)
    server_state = %{server_state |
      vote_state: %{
        term: server_state.current_term,
        votes_received: MapSet.new(),
        votes_granted: MapSet.new()
      }
    }
    {:ok, next_term_state, candidate_state, broadcast_request} = Candidate.init(server_state)

    {:ok, %{
      node_id: node_id,
      server_state: server_state,
      next_term_state: next_term_state,
      candidate_state: candidate_state,
      broadcast_request: broadcast_request
    }}
  end

  describe "initialization" do
    test "starts election with proper state", context do
      assert context.candidate_state.election_timer_ref != nil
      assert context.candidate_state.election_timeout >= 150
      assert context.candidate_state.election_timeout <= 300
      assert MapSet.member?(context.candidate_state.votes_received, context.node_id)
      assert context.candidate_state.election_start != nil

      # Test term increment
      assert context.next_term_state.current_term == context.server_state.current_term + 1

      # Test broadcast request
      assert {:broadcast, request} = context.broadcast_request
      assert request.term == context.next_term_state.current_term
      assert request.candidate_id == context.node_id
    end

    test "creates different timeouts", %{server_state: server_state} do
      {:ok, _, state1, _} = Candidate.init(server_state)
      {:ok, _, state2, _} = Candidate.init(server_state)

      assert state1.election_timeout != state2.election_timeout
    end
  end

  describe "append entries handling" do
    test "rejects append entries from older term", context do
      message = AppendEntries.new(
        context.next_term_state.current_term - 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:ok, _state, _candidate_state, response} =
        Candidate.handle_append_entries(message, context.next_term_state, context.candidate_state)

      assert response.success == false
      assert response.term == context.next_term_state.current_term
    end

    test "steps down for current or higher term append entries", context do
      message = AppendEntries.new(
        context.next_term_state.current_term,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:transition, :follower, state} =
        Candidate.handle_append_entries(message, context.next_term_state, context.candidate_state)

      assert state == context.next_term_state
    end
  end

  describe "request vote handling" do
    test "rejects vote requests from same or lower term", context do
      message = RequestVote.new(
        context.next_term_state.current_term,
        NodeId.generate(),
        0,
        0
      )

      {:ok, _state, _candidate_state, response} =
        Candidate.handle_request_vote(message, context.next_term_state, context.candidate_state)

      assert response.vote_granted == false
      assert response.term == context.next_term_state.current_term
    end

    test "steps down for higher term request", context do
      message = RequestVote.new(
        context.next_term_state.current_term + 1,
        NodeId.generate(),
        0,
        0
      )

      {:transition, :follower, state} =
        Candidate.handle_request_vote(message, context.next_term_state, context.candidate_state)

      assert state == context.next_term_state
    end
  end

  describe "request vote response handling" do
    test "transitions to leader on majority votes", context do
      # Create vote from another node
      message = RequestVoteResponse.new(
        context.next_term_state.current_term,
        true,
        NodeId.generate()
      )

      {:transition, :leader, state} =
        Candidate.handle_request_vote_response(
          message,
          context.next_term_state,
          context.candidate_state
        )

      assert state == context.next_term_state
    end

    test "continues as candidate without majority", context do
      # Set up state with no votes yet
      candidate_state = %{context.candidate_state |
        votes_received: MapSet.new()
      }

      message = RequestVoteResponse.new(
        context.next_term_state.current_term,
        true,
        NodeId.generate()
      )

      {:ok, state, new_state} =
        Candidate.handle_request_vote_response(
          message,
          context.next_term_state,
          candidate_state
        )

      assert state == context.next_term_state
      assert MapSet.size(new_state.votes_received) == 1
    end

    test "ignores votes from different terms", context do
      message = RequestVoteResponse.new(
        context.next_term_state.current_term - 1,
        true,
        NodeId.generate()
      )

      {:ok, state, candidate_state} =
        Candidate.handle_request_vote_response(
          message,
          context.next_term_state,
          context.candidate_state
        )

      assert state == context.next_term_state
      assert candidate_state == context.candidate_state
    end

    test "ignores duplicate votes", context do
      voter_id = NodeId.generate()
      # First set up the server_state with vote_state
      server_state = %{context.next_term_state |
        vote_state: %{
          term: context.next_term_state.current_term,
          votes_received: MapSet.new([voter_id]),
          votes_granted: MapSet.new([voter_id])
        }
      }

      message = RequestVoteResponse.new(
        context.next_term_state.current_term,
        true,
        voter_id
      )

      # Handle that we might get a leader transition or an ok response
      result = Candidate.handle_request_vote_response(
        message,
        server_state,
        context.candidate_state
      )

      case result do
        # {:transition, :leader, state} ->
        #   assert state == server_state
        {:ok, state, new_state} ->
          assert state == server_state
          assert new_state.votes_received == context.candidate_state.votes_received
      end
    end
  end

  describe "timeout handling" do
    test "starts new election on election timeout", context do
      {:transition, :candidate, state} =
        Candidate.handle_timeout(:election, context.next_term_state, context.candidate_state)

      assert state == context.next_term_state
    end

    test "ignores non-election timeouts", context do
      {:ok, state, candidate_state} =
        Candidate.handle_timeout(:unknown, context.next_term_state, context.candidate_state)

      assert state == context.next_term_state
      assert candidate_state == context.candidate_state
    end
  end

  describe "client command handling" do
    test "rejects client commands", context do
      assert {:error, :no_leader} =
        Candidate.handle_client_command(
          "command",
          context.next_term_state,
          context.candidate_state
        )
    end
  end
end
