defmodule ElixirRaft.Consensus.MessageDispatcherTest do
  use ExUnit.Case, async: false

  alias ElixirRaft.Core.{NodeId, LogEntry}
  alias ElixirRaft.Storage.{StateStore, LogStore}
  alias ElixirRaft.RPC.Messages
  alias ElixirRaft.Consensus.MessageDispatcher

  @moduletag :capture_log
  @timeout 5000

  setup do
    # Create unique test directory
    test_id = System.unique_integer([:positive])
    base_dir = System.tmp_dir!()
    test_dir = Path.join([base_dir, "raft_test_#{test_id}"])
    File.mkdir_p!(test_dir)

    # Generate node ID
    node_id = NodeId.generate()

    # Start stores
    {:ok, state_store} = start_state_store(node_id, test_dir)
    {:ok, log_store} = start_log_store(test_dir)

    # Start message dispatcher
    {:ok, dispatcher} = MessageDispatcher.start_link(
      node_id: node_id,
      state_store: state_store,
      log_store: log_store
    )

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, %{
      node_id: node_id,
      dispatcher: dispatcher,
      state_store: state_store,
      log_store: log_store,
      test_dir: test_dir
    }}
  end

  test "initialization starts with follower role", %{dispatcher: dispatcher} do
    assert {:ok, %{role: :follower}} = MessageDispatcher.get_state(dispatcher)
  end

  test "initialization fails with invalid node_id" do
    assert {:error, _} = MessageDispatcher.start_link(
      node_id: "invalid",
      state_store: nil,
      log_store: nil
    )
  end

  test "message dispatching handles append entries message", context do
    %{dispatcher: dispatcher, node_id: node_id} = context

    # Create append entries message
    msg = Messages.AppendEntries.new(
      1, # term
      "leader-id",
      0, # prev_log_index
      0, # prev_log_term
      [%LogEntry{index: 1, term: 1, command: "test"}],
      0  # leader_commit
    )

    # Send message
    :ok = MessageDispatcher.handle_message(dispatcher, msg)

    # Verify state updated
    {:ok, state} = MessageDispatcher.get_state(dispatcher)
    assert state.current_term == 1
  end

  test "message dispatching handles request vote message", context do
    %{dispatcher: dispatcher, node_id: node_id} = context

    msg = Messages.RequestVote.new(
      1, # term
      "candidate-id",
      0, # last_log_index
      0  # last_log_term
    )

    :ok = MessageDispatcher.handle_message(dispatcher, msg)

    {:ok, state} = MessageDispatcher.get_state(dispatcher)
    assert state.current_term == 1
  end

  test "message dispatching rejects invalid messages", %{dispatcher: dispatcher} do
    assert {:error, :invalid_message} = MessageDispatcher.handle_message(dispatcher, :invalid)
  end

  test "role transitions transitions from follower to candidate", context do
    %{dispatcher: dispatcher} = context

    :ok = MessageDispatcher.transition_to(dispatcher, :candidate)

    {:ok, state} = MessageDispatcher.get_state(dispatcher)
    assert state.role == :candidate
  end

  test "role transitions transitions to follower on higher term", context do
    %{dispatcher: dispatcher} = context

    # First become candidate
    :ok = MessageDispatcher.transition_to(dispatcher, :candidate)

    # Receive higher term message
    msg = Messages.AppendEntries.new(5, "leader-id", 0, 0, [], 0)
    :ok = MessageDispatcher.handle_message(dispatcher, msg)

    {:ok, state} = MessageDispatcher.get_state(dispatcher)
    assert state.role == :follower
    assert state.current_term == 5
  end

  test "error handling handles invalid role transitions", %{dispatcher: dispatcher} do
    assert {:error, :invalid_transition} = MessageDispatcher.transition_to(dispatcher, :invalid_role)
  end

  test "error handling maintains state on handler errors", context do
    %{dispatcher: dispatcher} = context

    {:ok, original_state} = MessageDispatcher.get_state(dispatcher)

    # Try invalid operation
    MessageDispatcher.handle_message(dispatcher, :invalid)

    {:ok, new_state} = MessageDispatcher.get_state(dispatcher)
    assert new_state == original_state
  end

  # Helper functions

  defp start_state_store(node_id, data_dir) do
    StateStore.start_link(
      node_id: node_id,
      data_dir: data_dir,
      name: :"state_store_#{node_id}"
    )
  end

  defp start_log_store(data_dir) do
    LogStore.start_link(
      data_dir: data_dir,
      name: :"log_store_#{data_dir}"
    )
  end
end
