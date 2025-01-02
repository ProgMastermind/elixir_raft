defmodule ElixirRaft.Core.ServerStateTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Core.ServerState
  alias ElixirRaft.Core.NodeId

  setup do
    node_id = NodeId.generate()
    {:ok, node_id: node_id, state: ServerState.new(node_id)}
  end

  describe "new/1" do
    test "creates new state with correct defaults", %{node_id: node_id} do
      state = ServerState.new(node_id)
      assert state.node_id == node_id
      assert state.current_term == 0
      assert state.role == :follower
      assert state.voted_for == nil
      assert state.current_leader == nil
      assert state.vote_state == nil
    end
  end

  describe "maybe_update_term/2" do
    test "updates term and becomes follower when receiving higher term", %{state: state} do
      {:ok, new_state} = ServerState.maybe_update_term(state, 2)
      assert new_state.current_term == 2
      assert new_state.role == :follower
      assert new_state.voted_for == nil
    end

    test "ignores lower terms", %{state: state} do
      state = %{state | current_term: 2}
      {:ok, new_state} = ServerState.maybe_update_term(state, 1)
      assert new_state == state
    end
  end

  describe "become_candidate/1" do
    test "transitions to candidate with incremented term", %{state: state} do
      {:ok, new_state} = ServerState.become_candidate(state)
      assert new_state.role == :candidate
      assert new_state.current_term == state.current_term + 1
      assert new_state.voted_for == state.node_id
      assert new_state.vote_state.votes_received == MapSet.new([state.node_id])
    end
  end

  describe "become_leader/1" do
    test "candidate can become leader", %{state: state} do
      {:ok, candidate} = ServerState.become_candidate(state)
      {:ok, leader} = ServerState.become_leader(candidate)
      assert leader.role == :leader
      assert leader.current_leader == leader.node_id
    end

    test "follower cannot become leader", %{state: state} do
      assert {:error, _} = ServerState.become_leader(state)
    end
  end

  describe "record_vote/3" do
    setup %{state: state} do
      {:ok, candidate} = ServerState.become_candidate(state)
      {:ok, candidate: candidate}
    end

    test "records granted vote", %{candidate: state} do
      voter_id = NodeId.generate()
      {:ok, new_state} = ServerState.record_vote(state, voter_id, true)
      assert MapSet.member?(new_state.vote_state.votes_granted, voter_id)
    end

    test "records denied vote", %{candidate: state} do
      voter_id = NodeId.generate()
      {:ok, new_state} = ServerState.record_vote(state, voter_id, false)
      refute MapSet.member?(new_state.vote_state.votes_granted, voter_id)
      assert MapSet.member?(new_state.vote_state.votes_received, voter_id)
    end
  end

  describe "has_quorum?/2" do
    test "returns true with majority votes", %{state: state} do
      {:ok, candidate} = ServerState.become_candidate(state)
      voter1 = NodeId.generate()
      voter2 = NodeId.generate()

      {:ok, candidate} = ServerState.record_vote(candidate, voter1, true)
      {:ok, candidate} = ServerState.record_vote(candidate, voter2, true)

      assert ServerState.has_quorum?(candidate, 3)
    end

    test "returns false without majority", %{state: state} do
      {:ok, candidate} = ServerState.become_candidate(state)
      refute ServerState.has_quorum?(candidate, 3)
    end
  end

  describe "leader_timed_out?/2" do
    test "returns true when no leader contact", %{state: state} do
      assert ServerState.leader_timed_out?(state, 1000)
    end

    test "returns false right after leader contact", %{state: state} do
      {:ok, state} = ServerState.record_leader_contact(state, NodeId.generate())
      refute ServerState.leader_timed_out?(state, 1000)
    end

    test "returns true after timeout", %{state: state} do
      {:ok, state} = ServerState.record_leader_contact(state, NodeId.generate())
      :timer.sleep(50)
      assert ServerState.leader_timed_out?(state, 25)
    end
  end
end
