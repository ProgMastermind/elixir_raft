defmodule ElixirRaft.Storage.StateStoreTest do
  use ExUnit.Case

  alias ElixirRaft.Storage.StateStore
  alias ElixirRaft.Core.{NodeId, ClusterConfig}

  @base_timeout 1000

  setup do
    node_id = NodeId.generate()
    test_dir = "test/tmp/state_store_#{node_id}"
    File.mkdir_p!(test_dir)

    opts = [
      node_id: node_id,
      data_dir: test_dir,
      sync_writes: true
    ]

    {:ok, pid} = StateStore.start_link(opts)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{
      server: pid,
      node_id: node_id,
      test_dir: test_dir
    }
  end

  describe "initialization" do
    test "starts with initial state", %{server: server} do
      assert {:ok, 0} = StateStore.get_current_term(server)
      assert {:ok, nil} = StateStore.get_voted_for(server)
      assert {:ok, nil} = StateStore.get_cluster_config(server)
    end

    test "persists state across restarts", %{server: server, node_id: node_id, test_dir: test_dir} do
      # Save some state
      :ok = StateStore.save_term(server, 5)
      :ok = StateStore.save_vote(server, node_id)

      # Stop the server
      GenServer.stop(server)

      # Start a new instance
      {:ok, new_server} = StateStore.start_link(
        node_id: node_id,
        data_dir: test_dir,
        sync_writes: true
      )

      # Verify state is preserved
      assert {:ok, 5} = StateStore.get_current_term(new_server)
      assert {:ok, ^node_id} = StateStore.get_voted_for(new_server)  # Added pin operator
    end
  end

  describe "term management" do
    test "saves and retrieves term", %{server: server} do
      :ok = StateStore.save_term(server, 1)
      assert {:ok, 1} = StateStore.get_current_term(server)

      :ok = StateStore.save_term(server, 2)
      assert {:ok, 2} = StateStore.get_current_term(server)
    end

    test "validates term before saving", %{server: server} do
      assert {:error, _} = StateStore.save_term(server, -1)
      assert {:error, _} = StateStore.save_term(server, "invalid")
    end
  end

  describe "vote management" do
    test "saves and retrieves vote", %{server: server} do
      voter_id = NodeId.generate()
      :ok = StateStore.save_vote(server, voter_id)
      assert {:ok, ^voter_id} = StateStore.get_voted_for(server)

      :ok = StateStore.save_vote(server, nil)
      assert {:ok, nil} = StateStore.get_voted_for(server)
    end

    test "validates vote before saving", %{server: server} do
      assert {:error, _} = StateStore.save_vote(server, "invalid")
    end
  end

  describe "cluster configuration" do
    test "saves and retrieves cluster config", %{server: server} do
      nodes = for _ <- 1..3, do: NodeId.generate()
      {:ok, config} = ClusterConfig.new(nodes, 1)

      :ok = StateStore.save_cluster_config(server, config)
      {:ok, saved_config} = StateStore.get_cluster_config(server)

      assert saved_config.current_members == config.current_members
      assert saved_config.state == config.state
    end

    test "validates cluster config before saving", %{server: server} do
      assert {:error, _} = StateStore.save_cluster_config(server, "invalid")
    end
  end

  describe "atomic state updates" do
    test "saves complete state atomically", %{server: server, node_id: node_id} do
      nodes = for _ <- 1..3, do: NodeId.generate()
      {:ok, config} = ClusterConfig.new(nodes, 1)

      state_data = %{
        current_term: 5,
        voted_for: node_id,
        cluster_config: config
      }

      :ok = StateStore.save_state(server, state_data)  # Added server parameter

      assert {:ok, 5} = StateStore.get_current_term(server)
      assert {:ok, ^node_id} = StateStore.get_voted_for(server)  # Added pin operator
      assert {:ok, saved_config} = StateStore.get_cluster_config(server)
      assert saved_config == config
    end

    test "handles concurrent writes safely", %{server: server, node_id: node_id} do
      # Spawn multiple processes to write simultaneously
      _processes = for i <- 1..10 do
        spawn_link(fn ->
          :ok = StateStore.save_term(server, i)
          :ok = StateStore.save_vote(server, node_id)
        end)
      end

      # Wait for all processes to complete
      :timer.sleep(@base_timeout)

      # Verify state is consistent
      {:ok, term} = StateStore.get_current_term(server)
      {:ok, voted_for} = StateStore.get_voted_for(server)

      assert is_integer(term)
      assert voted_for in [nil, node_id]
    end
  end

  describe "error handling" do
    test "handles corrupted state file", %{server: server, test_dir: test_dir} do
      state_path = Path.join(test_dir, "state.dat")
      File.write!(state_path, "corrupted data")

      # Stop the server
      GenServer.stop(server)

      # Should start with initial state when corrupted
      {:ok, new_server} = StateStore.start_link(
        node_id: NodeId.generate(),
        data_dir: test_dir,
        sync_writes: true
      )

      # Should initialize with default state
      assert {:ok, 0} = StateStore.get_current_term(new_server)
      assert {:ok, nil} = StateStore.get_voted_for(new_server)
    end

    test "handles disk full scenario", %{server: server, test_dir: test_dir} do
      # Simulate disk full by making directory read-only
      File.chmod!(test_dir, 0o444)

      assert {:error, _} = StateStore.save_term(server, 1)

      # Restore permissions
      File.chmod!(test_dir, 0o755)
    end
  end
end
