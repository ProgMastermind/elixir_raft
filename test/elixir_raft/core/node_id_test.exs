defmodule ElixirRaft.Core.NodeIdTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Core.NodeId

  describe "generate/0" do
    test "generates valid UUID v4" do
      node_id = NodeId.generate()
      assert {:ok, _} = NodeId.validate(node_id)
    end

    test "generates unique IDs" do
      ids = for _ <- 1..1000, do: NodeId.generate()
      unique_ids = Enum.uniq(ids)
      assert length(ids) == length(unique_ids)
    end
  end

  describe "validate/1" do
    test "accepts valid UUID" do
      node_id = UUID.uuid4()
      assert {:ok, ^node_id} = NodeId.validate(node_id)
    end

    test "rejects invalid UUID format" do
      assert {:error, "Invalid node ID format"} = NodeId.validate("invalid-uuid")
    end

    test "rejects non-string input" do
      assert {:error, "Node ID must be a string"} = NodeId.validate(123)
    end
  end

  describe "validate!/1" do
    test "returns valid node ID unchanged" do
      node_id = UUID.uuid4()
      assert ^node_id = NodeId.validate!(node_id)
    end

    test "raises for invalid node ID" do
      assert_raise ArgumentError, "Invalid node ID format", fn ->
        NodeId.validate!("invalid-uuid")
      end
    end
  end

  describe "compare/2" do
    test "correctly orders node IDs" do
      id1 = "00000000-0000-0000-0000-000000000001"
      id2 = "00000000-0000-0000-0000-000000000002"

      assert :lt = NodeId.compare(id1, id2)
      assert :gt = NodeId.compare(id2, id1)
      assert :eq = NodeId.compare(id1, id1)
    end
  end
end
