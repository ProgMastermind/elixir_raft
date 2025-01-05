defmodule ElixirRaft.Consensus.StateMachineTest do
  use ExUnit.Case, async: true
  require Logger

  alias ElixirRaft.Consensus.StateMachine
  alias ElixirRaft.Core.{LogEntry, NodeId}
  alias ElixirRaft.Storage.LogStore

  @node_id NodeId.generate()  # Generate a valid UUID for testing
  @temp_dir "test/tmp/state_machine"

  setup do
    # Ensure clean test directory
    File.rm_rf!(@temp_dir)
    File.mkdir_p!(@temp_dir)

    # Start LogStore
    log_store = start_supervised!({
      LogStore,
      [
        node_id: @node_id,
        data_dir: Path.join(@temp_dir, "log")
      ]
    })

    # Start StateMachine
    state_machine = start_supervised!({
      StateMachine,
      [
        node_id: @node_id,
        log_store: log_store,
        snapshot_dir: Path.join(@temp_dir, "snapshots")
      ]
    })

    {:ok, state_machine: state_machine, log_store: log_store}
  end

  describe "initialization" do
    test "starts with empty state", %{state_machine: machine} do
      assert {:ok, state} = StateMachine.get_state(machine)
      assert state == %{}
    end

    test "rejects invalid node_id" do
      assert {:error, _} = start_supervised({
        StateMachine,
        [
          node_id: "invalid-node-id",
          log_store: nil,
          snapshot_dir: @temp_dir,
          name: :invalid_node_machine
        ]
      })
    end
  end

  describe "command application" do
    test "applies set commands", %{state_machine: machine} do
      entries = [
        create_entry(1, {:set, :key1, "value1"}),
        create_entry(2, {:set, :key2, "value2"})
      ]

      assert {:ok, 2} = StateMachine.apply_entries(machine, entries, 2)
      assert {:ok, state} = StateMachine.get_state(machine)
      assert state == %{key1: "value1", key2: "value2"}
    end

    test "applies delete commands", %{state_machine: machine} do
      entries = [
        create_entry(1, {:set, :key1, "value1"}),
        create_entry(2, {:delete, :key1})
      ]

      assert {:ok, 2} = StateMachine.apply_entries(machine, entries, 2)
      assert {:ok, state} = StateMachine.get_state(machine)
      assert state == %{}
    end

    test "respects commit index", %{state_machine: machine} do
      entries = [
        create_entry(1, {:set, :key1, "value1"}),
        create_entry(2, {:set, :key2, "value2"})
      ]

      assert {:ok, 1} = StateMachine.apply_entries(machine, entries, 1)
      assert {:ok, state} = StateMachine.get_state(machine)
      assert state == %{key1: "value1"}
    end
  end

  describe "snapshots" do
    test "creates and restores snapshots", %{state_machine: machine} do
      # Apply some entries
      entries = [
        create_entry(1, {:set, :key1, "value1"}),
        create_entry(2, {:set, :key2, "value2"})
      ]

      {:ok, 2} = StateMachine.apply_entries(machine, entries, 2)

      # Create snapshot
      assert {:ok, snapshot} = StateMachine.create_snapshot(machine)

      # Create a new state machine with a different node_id for restoration
      snapshot_dir = Path.join(@temp_dir, "snapshots_restore")
      File.mkdir_p!(snapshot_dir)

      other_node_id = NodeId.generate()  # Generate a new valid UUID
      other_machine = start_supervised!(
        {StateMachine,
         [
           node_id: other_node_id,
           log_store: nil,
           snapshot_dir: snapshot_dir,
           name: :other_machine
         ]},
        id: :other_machine
      )

      assert :ok = StateMachine.restore_snapshot(other_machine, snapshot)
      assert {:ok, state} = StateMachine.get_state(other_machine)
      assert state == %{key1: "value1", key2: "value2"}
    end

    test "rejects invalid snapshots", %{state_machine: machine} do
      invalid_snapshot = {-1, %{}}
      assert {:error, :invalid_snapshot} =
        StateMachine.restore_snapshot(machine, invalid_snapshot)
    end
  end

  describe "queries" do
    test "handles existing keys", %{state_machine: machine} do
      entries = [create_entry(1, {:set, :key1, "value1"})]
      {:ok, 1} = StateMachine.apply_entries(machine, entries, 1)

      assert {:ok, "value1"} = StateMachine.query(machine, :key1)
    end

    test "handles non-existing keys", %{state_machine: machine} do
      assert {:ok, {:error, :not_found}} = StateMachine.query(machine, :nonexistent)
    end
  end

  # Helper Functions

  defp create_entry(index, command) do
    %LogEntry{
      index: index,
      term: 1,
      command: command,
      created_at: DateTime.utc_now()
    }
  end
end
