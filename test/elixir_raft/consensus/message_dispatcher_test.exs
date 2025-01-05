defmodule ElixirRaft.Consensus.MessageDispatcherTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.Consensus.MessageDispatcher
  alias ElixirRaft.RPC.Messages.{
    AppendEntries,
    AppendEntriesResponse,
    RequestVote,
    RequestVoteResponse
  }

  @node_id "node_1"

  setup do
    dispatcher = start_supervised!({
      MessageDispatcher,
      [node_id: @node_id]
    })
    {:ok, dispatcher: dispatcher}
  end

  describe "initialization" do
    test "starts with follower role", %{dispatcher: dispatcher} do
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)
    end
  end

  describe "message dispatching" do
    test "handles append entries message", %{dispatcher: dispatcher} do
      message = %AppendEntries{
        term: 1,
        leader_id: "leader_1",
        prev_log_index: 0,
        prev_log_term: 0,
        entries: [],
        leader_commit: 0
      }

      assert {:ok, response} = MessageDispatcher.dispatch_message(dispatcher, message)
      assert %AppendEntriesResponse{} = response
      assert response.term == 1
    end

    test "handles request vote message", %{dispatcher: dispatcher} do
      message = %RequestVote{
        term: 1,
        candidate_id: "candidate_1",
        last_log_index: 0,
        last_log_term: 0
      }

      assert {:ok, response} = MessageDispatcher.dispatch_message(dispatcher, message)
      assert %RequestVoteResponse{} = response
      assert response.term == 1
    end

    test "rejects messages with invalid format", %{dispatcher: dispatcher} do
      assert {:error, :unknown_message_type} =
        MessageDispatcher.dispatch_message(dispatcher, {:invalid_message})
    end
  end

  describe "role transitions" do
    test "transitions from follower to candidate", %{dispatcher: dispatcher} do
      assert :ok = MessageDispatcher.transition_to(dispatcher, :candidate)
      assert {:ok, :candidate} = MessageDispatcher.get_current_role(dispatcher)
    end

    test "transitions to follower when receiving higher term", %{dispatcher: dispatcher} do
      # First become candidate
      :ok = MessageDispatcher.transition_to(dispatcher, :candidate)

      # Receive append entries with higher term
      message = %AppendEntries{
        term: 2,
        leader_id: "leader_1",
        prev_log_index: 0,
        prev_log_term: 0,
        entries: [],
        leader_commit: 0
      }

      {:ok, _response} = MessageDispatcher.dispatch_message(dispatcher, message)
      assert {:ok, :follower} = MessageDispatcher.get_current_role(dispatcher)
    end
  end

  describe "error handling" do
    test "handles role transition errors", %{dispatcher: dispatcher} do
      assert {:error, _reason} = MessageDispatcher.transition_to(dispatcher, :invalid_role)
    end

    test "maintains state on handler errors", %{dispatcher: dispatcher} do
      {:ok, initial_role} = MessageDispatcher.get_current_role(dispatcher)

      # Trigger error with invalid message
      MessageDispatcher.dispatch_message(dispatcher, :invalid)

      assert {:ok, ^initial_role} = MessageDispatcher.get_current_role(dispatcher)
    end
  end
end
