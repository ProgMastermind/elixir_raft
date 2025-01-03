defmodule ElixirRaft.Core.ClusterConfigTest do
  use ExUnit.Case, async: true

  alias ElixirRaft.Core.ClusterConfig

  @valid_nodes ["node1", "node2", "node3"]
    @invalid_nodes [1, :node, "node"]
    @initial_term 1

    describe "new/2" do
        test "creates new configuration with valid members" do
          assert {:ok, config} = ClusterConfig.new(@valid_nodes, @initial_term)
          assert config.state == :stable
          assert config.config_index == 0
          assert config.current_term == @initial_term
          assert MapSet.size(config.current_members) == 3
          assert Enum.all?(@valid_nodes, &MapSet.member?(config.current_members, &1))
        end

        test "rejects empty member list" do
          assert {:error, "Member list cannot be empty"} = ClusterConfig.new([])
        end

        test "rejects invalid node IDs" do
          assert {:error, "Invalid node ID format"} = ClusterConfig.new(@invalid_nodes)
        end
      end

    describe "begin_change/3" do
        setup do
          {:ok, config} = ClusterConfig.new(@valid_nodes, @initial_term)
          {:ok, config: config}
        end

        test "starts valid configuration change", %{config: config} do
          to_add = ["node4"]
          to_remove = ["node1"]

          assert {:ok, new_config, entry} = ClusterConfig.begin_change(config, to_add, to_remove)

          assert {:joint, old, new} = new_config.state
          assert MapSet.equal?(old, config.current_members)
          assert MapSet.size(new) == 3
          assert MapSet.member?(new, "node4")
          assert not MapSet.member?(new, "node1")

          assert entry.type == :config_change
          assert match?({:config_change, :begin, ^to_add, ^to_remove}, entry.command)
        end

        test "rejects change during joint consensus", %{config: config} do
          {:ok, config_in_change, _} = ClusterConfig.begin_change(config, ["node4"], ["node1"])

          assert {:error, "Configuration change already in progress"} =
            ClusterConfig.begin_change(config_in_change, ["node5"], ["node2"])
        end

        test "rejects adding existing member", %{config: config} do
          assert {:error, "Cannot add existing member"} =
            ClusterConfig.begin_change(config, ["node1"], [])
        end

        test "rejects removing non-existent member", %{config: config} do
          assert {:error, "Cannot remove non-existent member"} =
            ClusterConfig.begin_change(config, [], ["node4"])
        end

        test "rejects changes that would lose quorum", %{config: config} do
          assert {:error, "Configuration change would lose quorum capability"} =
            ClusterConfig.begin_change(config, [], ["node1", "node2"])
        end
      end

  describe "commit_change/1" do
    setup do
      {:ok, config} = ClusterConfig.new(@valid_nodes)
      {:ok, config_in_change, _} = ClusterConfig.begin_change(config, ["node4"], ["node1"])
      {:ok, config: config, config_in_change: config_in_change}
    end

    test "commits configuration change", %{config_in_change: config} do
      assert {:ok, new_config, entry} = ClusterConfig.commit_change(config)

      assert new_config.state == :stable
      assert MapSet.size(new_config.current_members) == 3
      assert MapSet.member?(new_config.current_members, "node4")
      assert not MapSet.member?(new_config.current_members, "node1")

      assert entry.type == :config_change
      assert match?({:config_change, :commit}, entry.command)
    end

    test "rejects commit with no change in progress", %{config: config} do
      assert {:error, "No configuration change in progress"} = ClusterConfig.commit_change(config)
    end
  end

  describe "is_member?/2" do
    setup do
      {:ok, config} = ClusterConfig.new(@valid_nodes)
      {:ok, config_in_change, _} = ClusterConfig.begin_change(config, ["node4"], ["node1"])
      {:ok, config: config, config_in_change: config_in_change}
    end

    test "correctly identifies members in stable config", %{config: config} do
      assert ClusterConfig.is_member?(config, "node1")
      assert not ClusterConfig.is_member?(config, "node4")
    end

    test "correctly identifies members during joint consensus", %{config_in_change: config} do
      assert ClusterConfig.is_member?(config, "node1")
      assert ClusterConfig.is_member?(config, "node4")
    end
  end

  describe "quorum_size/1" do
    setup do
      {:ok, config} = ClusterConfig.new(@valid_nodes)
      {:ok, config_in_change, _} = ClusterConfig.begin_change(config, ["node4"], ["node1"])
      {:ok, config: config, config_in_change: config_in_change}
    end

    test "calculates correct quorum size for stable config", %{config: config} do
      assert ClusterConfig.quorum_size(config) == 2
    end

    test "calculates correct quorum sizes during joint consensus", %{config_in_change: config} do
      assert [2, 2] = ClusterConfig.quorum_size(config)
    end
  end

  describe "has_quorum?/2" do
    setup do
      {:ok, config} = ClusterConfig.new(@valid_nodes)
      {:ok, config_in_change, _} = ClusterConfig.begin_change(config, ["node4"], ["node1"])
      {:ok, config: config, config_in_change: config_in_change}
    end

    test "correctly determines quorum in stable config", %{config: config} do
      assert ClusterConfig.has_quorum?(config, MapSet.new(["node1", "node2"]))
      assert not ClusterConfig.has_quorum?(config, MapSet.new(["node1"]))
    end

    test "correctly determines quorum during joint consensus", %{config_in_change: config} do
      # Need majority in both old and new configurations
      assert ClusterConfig.has_quorum?(
        config,
        MapSet.new(["node1", "node2", "node4"])
      )

      assert not ClusterConfig.has_quorum?(
        config,
        MapSet.new(["node1", "node2"])
      )
    end
  end
end
