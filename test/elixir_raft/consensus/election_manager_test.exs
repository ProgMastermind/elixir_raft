defmodule ElixirRaft.Consensus.ElectionManagerTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.Consensus.ElectionManager
  alias ElixirRaft.Core.NodeId

  @node_id NodeId.generate()
  @node_id2 NodeId.generate()
  @cluster_size 3
  @initial_term 1

  setup do
    manager = start_supervised!({
      ElectionManager,
      [
        node_id: @node_id,
        cluster_size: @cluster_size,
        current_term: @initial_term
      ]
    })
    {:ok, manager: manager}
  end

  describe "initialization" do
    test "starts in follower state", %{manager: manager} do
      assert {:ok, nil} = ElectionManager.get_leader(manager)
      assert {:ok, @initial_term} = ElectionManager.get_current_term(manager)
    end

    test "fails with invalid node ID" do
      assert {:error, _} = start_supervised({
        ElectionManager,
        [
          node_id: "invalid-uuid",
          cluster_size: @cluster_size,
          current_term: @initial_term
        ]
      })
    end
  end

  describe "election process" do
    test "starts election when triggered", %{manager: manager} do
      :ok = ElectionManager.start_election(manager)
      # Term should be incremented
      {:ok, term} = ElectionManager.get_current_term(manager)
      assert term == @initial_term + 1
      # Should count own vote
      assert {:ok, :not_elected} =
        ElectionManager.record_vote(manager, @node_id, true, term)
    end

    test "becomes leader with majority votes", %{manager: manager} do
      :ok = ElectionManager.start_election(manager)
      {:ok, current_term} = ElectionManager.get_current_term(manager)
      # Record vote from another node
      assert {:ok, :elected} =
        ElectionManager.record_vote(manager, @node_id2, true, current_term)
      # Should be leader now
      assert {:ok, @node_id} = ElectionManager.get_leader(manager)
    end

    test "remains candidate with insufficient votes", %{manager: manager} do
      :ok = ElectionManager.start_election(manager)
      {:ok, current_term} = ElectionManager.get_current_term(manager)
      # Record rejected vote
      assert {:ok, :not_elected} =
        ElectionManager.record_vote(manager, @node_id2, false, current_term)
      # Should still have no leader
      assert {:ok, nil} = ElectionManager.get_leader(manager)
    end

    test "rejects votes with invalid node ID", %{manager: manager} do
      :ok = ElectionManager.start_election(manager)
      {:ok, current_term} = ElectionManager.get_current_term(manager)
      assert {:error, "Invalid node ID format"} =
        ElectionManager.record_vote(manager, "invalid-uuid", true, current_term)
    end
  end

  describe "term handling" do
    test "steps down on higher term", %{manager: manager} do
      # First become candidate
      :ok = ElectionManager.start_election(manager)
      # Step down due to higher term
      higher_term = @initial_term + 2
      :ok = ElectionManager.step_down(manager, higher_term)
      # Should update term and clear leader
      assert {:ok, ^higher_term} = ElectionManager.get_current_term(manager)
      assert {:ok, nil} = ElectionManager.get_leader(manager)
    end

    test "ignores lower terms", %{manager: manager} do
      lower_term = @initial_term - 1
      :ok = ElectionManager.step_down(manager, lower_term)
      assert {:ok, @initial_term} = ElectionManager.get_current_term(manager)
    end
  end

  describe "leader contact" do
    test "recognizes leader with valid term", %{manager: manager} do
      :ok = ElectionManager.record_leader_contact(manager, @node_id2, @initial_term)
      assert {:ok, @node_id2} = ElectionManager.get_leader(manager)
    end

    test "ignores leader with old term", %{manager: manager} do
      :ok = ElectionManager.record_leader_contact(manager, @node_id2, @initial_term - 1)
      assert {:ok, nil} = ElectionManager.get_leader(manager)
    end

    test "rejects invalid leader ID", %{manager: manager} do
      assert {:error, "Invalid node ID format"} =
        ElectionManager.record_leader_contact(manager, "invalid-uuid", @initial_term)
    end
  end

  describe "error handling" do
    test "rejects votes from wrong term", %{manager: manager} do
      :ok = ElectionManager.start_election(manager)
      assert {:error, :term_mismatch} =
        ElectionManager.record_vote(manager, @node_id2, true, @initial_term)
    end

    test "rejects votes when not candidate", %{manager: manager} do
      assert {:error, :not_candidate} =
        ElectionManager.record_vote(manager, @node_id2, true, @initial_term)
    end
  end
end
