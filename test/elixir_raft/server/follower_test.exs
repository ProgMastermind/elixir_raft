defmodule ElixirRaft.Server.FollowerTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Server.Follower
  alias ElixirRaft.Core.{ServerState, NodeId}
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
      message1 = RequestVote.new(
        context.server_state.current_term,
        candidate1_id,
        0,
        0
      )
      {:ok, voted_state, _follower_state, _response} =
        Follower.handle_request_vote(message1, context.server_state, context.follower_state)

      # Second vote attempt
      candidate2_id = NodeId.generate()
      message2 = RequestVote.new(
        context.server_state.current_term,
        candidate2_id,
        0,
        0
      )

      {:ok, _final_state, _follower_state, response} =
        Follower.handle_request_vote(message2, voted_state, context.follower_state)

      assert response.vote_granted == false
    end
  end

  describe "handle_timeout" do
    test "transitions to candidate on election timeout", context do
      {:transition, new_role, _server_state, _follower_state} =
        Follower.handle_timeout(:election, context.server_state, context.follower_state)

      assert new_role == :candidate
    end

    test "ignores non-election timeouts", context do
      {:ok, server_state, _follower_state} =
        Follower.handle_timeout(:unknown, context.server_state, context.follower_state)

      assert server_state == context.server_state
    end
  end

  describe "handle_client_command" do
    test "redirects to leader when leader is known", context do
      leader_id = NodeId.generate()
      server_state = %{context.server_state | current_leader: leader_id}

      {:redirect, redirect_leader_id, _state, _follower_state} =
        Follower.handle_client_command("command", server_state, context.follower_state)

      assert redirect_leader_id == leader_id
    end

    test "returns error when leader is unknown", context do
      {:error, :no_leader} =
        Follower.handle_client_command("command", context.server_state, context.follower_state)
    end
  end
end
