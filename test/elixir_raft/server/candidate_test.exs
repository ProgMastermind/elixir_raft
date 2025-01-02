defmodule ElixirRaft.Server.CandidateTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Server.Candidate
  alias ElixirRaft.Core.{ServerState, NodeId}
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    RequestVote,
    RequestVoteResponse,
  }

  setup do
    node_id = NodeId.generate()
    server_state = ServerState.new(node_id)
    {:ok, candidate_state} = Candidate.init(server_state)

    {:ok, %{
      node_id: node_id,
      server_state: server_state,
      candidate_state: candidate_state
    }}
  end

  describe "initialization" do
    test "starts election with proper state", %{
      server_state: _server_state,
      candidate_state: candidate_state,
      node_id: node_id
    } do
      assert candidate_state.election_timer_ref != nil
      assert candidate_state.election_timeout >= 150
      assert candidate_state.election_timeout <= 300
      assert MapSet.member?(candidate_state.votes_received, node_id)
    end

    test "creates different timeouts", %{server_state: server_state} do
      {:ok, state1} = Candidate.init(server_state)
      {:ok, state2} = Candidate.init(server_state)

      assert state1.election_timeout != state2.election_timeout
    end
  end

  describe "append entries handling" do
    test "rejects append entries from older term", context do
      message = AppendEntries.new(
        context.server_state.current_term - 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:ok, _state, _candidate_state, response} =
        Candidate.handle_append_entries(message, context.server_state, context.candidate_state)

      assert response.success == false
      assert response.term == context.server_state.current_term
    end

    test "steps down for current term append entries", context do
      message = AppendEntries.new(
        context.server_state.current_term,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:transition, :follower, _state, _candidate_state} =
        Candidate.handle_append_entries(message, context.server_state, context.candidate_state)
    end

    test "steps down for higher term append entries", context do
      message = AppendEntries.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0,
        [],
        0
      )

      {:transition, :follower, _state, _candidate_state} =
        Candidate.handle_append_entries(message, context.server_state, context.candidate_state)
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

      {:ok, _state, _candidate_state, response} =
        Candidate.handle_request_vote(message, context.server_state, context.candidate_state)

      assert response.vote_granted == false
    end

    test "steps down for higher term request", context do
      message = RequestVote.new(
        context.server_state.current_term + 1,
        NodeId.generate(),
        0,
        0
      )

      {:transition, :follower, _state, _candidate_state} =
        Candidate.handle_request_vote(message, context.server_state, context.candidate_state)
    end
  end

  describe "vote response handling" do
    test "collects votes and becomes leader on majority", context do
      # First vote is self vote from initialization
      # Add one more vote for majority
      message = RequestVoteResponse.new(
        context.server_state.current_term,
        true,
        NodeId.generate()
      )

      {:transition, :leader, _state, final_state} =
        Candidate.handle_request_vote_response(
          message,
          context.server_state,
          context.candidate_state
        )

      assert MapSet.size(final_state.votes_received) == 2
    end

    test "continues election without majority", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term,
        true,
        NodeId.generate()
      )

      # Increase required votes for testing
      candidate_state = %{context.candidate_state |
        votes_received: MapSet.new()
      }

      {:ok, _state, new_state} =
        Candidate.handle_request_vote_response(
          message,
          context.server_state,
          candidate_state
        )

      assert MapSet.size(new_state.votes_received) == 1
    end

    test "ignores votes from old term", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term - 1,
        true,
        NodeId.generate()
      )

      {:ok, state, candidate_state} =
        Candidate.handle_request_vote_response(
          message,
          context.server_state,
          context.candidate_state
        )

      assert state == context.server_state
      assert candidate_state == context.candidate_state
    end

    test "steps down on higher term response", context do
      message = RequestVoteResponse.new(
        context.server_state.current_term + 1,
        false,
        NodeId.generate()
      )

      {:transition, :follower, _state, _candidate_state} =
        Candidate.handle_request_vote_response(
          message,
          context.server_state,
          context.candidate_state
        )
    end
  end

  describe "timeout handling" do
    test "starts new election on timeout", context do
      {:ok, new_server_state, new_candidate_state} =
        Candidate.handle_timeout(:election, context.server_state, context.candidate_state)

      assert new_server_state.current_term > context.server_state.current_term
      assert MapSet.size(new_candidate_state.votes_received) == 1
      assert new_candidate_state.election_timer_ref != context.candidate_state.election_timer_ref
    end

    test "ignores non-election timeouts", context do
      {:ok, state, candidate_state} =
        Candidate.handle_timeout(:unknown, context.server_state, context.candidate_state)

      assert state == context.server_state
      assert candidate_state == context.candidate_state
    end
  end

  describe "client request handling" do
    test "rejects client requests", context do
      assert {:error, :no_leader} =
        Candidate.handle_client_command("command", context.server_state, context.candidate_state)
    end
  end
end
