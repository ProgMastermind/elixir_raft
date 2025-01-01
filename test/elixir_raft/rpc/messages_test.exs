defmodule ElixirRaft.RPC.MessagesTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.RPC.Messages.{RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse}
  alias ElixirRaft.Core.{LogEntry, NodeId}

  setup do
    node_id1 = NodeId.generate()
    node_id2 = NodeId.generate()
    {:ok, node_id1: node_id1, node_id2: node_id2}
  end

  describe "RequestVote" do
    test "creates valid request vote message", %{node_id1: node_id} do
      msg = RequestVote.new(1, node_id, 10, 1)
      assert msg.term == 1
      assert msg.candidate_id == node_id
      assert msg.last_log_index == 10
      assert msg.last_log_term == 1
    end

    test "validates request vote message", %{node_id1: node_id} do
      valid_msg = RequestVote.new(1, node_id, 10, 1)
      assert :ok = Messages.validate_request_vote(valid_msg)

      invalid_msgs = [
        RequestVote.new(-1, node_id, 10, 1),
        RequestVote.new(1, "invalid-id", 10, 1),
        RequestVote.new(1, node_id, -1, 1),
        RequestVote.new(1, node_id, 10, -1)
      ]

      for msg <- invalid_msgs do
        assert {:error, _} = Messages.validate_request_vote(msg)
      end
    end
  end

  describe "RequestVoteResponse" do
    test "creates valid request vote response", %{node_id1: node_id} do
      msg = RequestVoteResponse.new(1, true, node_id)
      assert msg.term == 1
      assert msg.vote_granted == true
      assert msg.voter_id == node_id
    end
  end

  describe "AppendEntries" do
    test "creates valid append entries message", %{node_id1: node_id} do
      {:ok, entry} = LogEntry.new(1, 1, "command")
      msg = AppendEntries.new(1, node_id, 0, 0, [entry], 0)

      assert msg.term == 1
      assert msg.leader_id == node_id
      assert msg.prev_log_index == 0
      assert msg.prev_log_term == 0
      assert length(msg.entries) == 1
      assert msg.leader_commit == 0
    end

    test "creates heartbeat message", %{node_id1: node_id} do
      msg = AppendEntries.heartbeat(1, node_id, 0, 0, 0)

      assert msg.term == 1
      assert msg.leader_id == node_id
      assert msg.entries == []
    end

    test "validates append entries message", %{node_id1: node_id} do
      {:ok, entry} = LogEntry.new(1, 1, "command")
      valid_msg = AppendEntries.new(1, node_id, 0, 0, [entry], 0)
      assert :ok = Messages.validate_append_entries(valid_msg)

      invalid_msgs = [
        AppendEntries.new(-1, node_id, 0, 0, [], 0),
        AppendEntries.new(1, "invalid-id", 0, 0, [], 0),
        AppendEntries.new(1, node_id, -1, 0, [], 0),
        AppendEntries.new(1, node_id, 0, -1, [], 0),
        AppendEntries.new(1, node_id, 0, 0, [], -1)
      ]

      for msg <- invalid_msgs do
        assert {:error, _} = Messages.validate_append_entries(msg)
      end
    end
  end

  describe "AppendEntriesResponse" do
    test "creates valid append entries response", %{node_id1: node_id} do
      msg = AppendEntriesResponse.new(1, true, node_id, 10)

      assert msg.term == 1
      assert msg.success == true
      assert msg.follower_id == node_id
      assert msg.match_index == 10
    end
  end

  describe "message encoding/decoding" do
    test "successfully encodes and decodes RequestVote", %{node_id1: node_id} do
      original = RequestVote.new(1, node_id, 10, 1)
      encoded = Messages.encode(original)
      assert {:ok, ^original} = Messages.decode(encoded)
    end

    test "successfully encodes and decodes AppendEntries", %{node_id1: node_id} do
      {:ok, entry} = LogEntry.new(1, 1, "command")
      original = AppendEntries.new(1, node_id, 0, 0, [entry], 0)
      encoded = Messages.encode(original)
      assert {:ok, ^original} = Messages.decode(encoded)
    end

    test "successfully encodes and decodes responses", %{node_id1: node_id} do
      vote_response = RequestVoteResponse.new(1, true, node_id)
      append_response = AppendEntriesResponse.new(1, true, node_id, 10)

      for msg <- [vote_response, append_response] do
        encoded = Messages.encode(msg)
        assert {:ok, ^msg} = Messages.decode(encoded)
      end
    end

    test "handles invalid binary data" do
      assert {:error, _} = Messages.decode(<<1, 2, 3>>)
    end

    test "handles invalid message types" do
      invalid = :erlang.term_to_binary(%{type: :invalid})
      assert {:error, "Unknown message type"} = Messages.decode(invalid)
    end
  end
end
