defmodule ElixirRaft.Core.LogEntryTest do
  use ExUnit.Case, async: true
  alias ElixirRaft.Core.LogEntry

  describe "new/4" do
    test "creates valid log entry with defaults" do
      {:ok, entry} = LogEntry.new(1, 0, "test command")

      assert entry.index == 1
      assert entry.term == 0
      assert entry.command == "test command"
      assert entry.type == :command
      assert %DateTime{} = entry.created_at
    end

    test "creates config change entry" do
      {:ok, entry} = LogEntry.new(1, 0, "config change", type: :config_change)
      assert entry.type == :config_change
    end

    test "rejects invalid index" do
      assert {:error, "Index must be a positive integer"} =
        LogEntry.new(0, 0, "test")
      assert {:error, "Index must be a positive integer"} =
        LogEntry.new(-1, 0, "test")
    end

    test "rejects invalid term" do
      assert {:error, "Term cannot be negative"} =
        LogEntry.new(1, -1, "test")
    end

    test "rejects invalid type" do
      assert {:error, "Invalid entry type"} =
        LogEntry.new(1, 0, "test", type: :invalid)
    end
  end

  describe "new!/4" do
    test "creates valid log entry" do
      entry = LogEntry.new!(1, 0, "test command")
      assert entry.index == 1
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, "Index must be a positive integer", fn ->
        LogEntry.new!(0, 0, "test")
      end
    end
  end

  describe "same_entry?/2" do
    setup do
      {:ok, entry1} = LogEntry.new(1, 1, "command1")
      {:ok, entry2} = LogEntry.new(1, 1, "command2")
      {:ok, entry3} = LogEntry.new(1, 2, "command1")
      {:ok, entry4} = LogEntry.new(2, 1, "command1")

      {:ok, %{
        entry1: entry1,
        entry2: entry2,
        entry3: entry3,
        entry4: entry4
      }}
    end

    test "identifies same entries", %{entry1: entry1, entry2: entry2} do
      assert LogEntry.same_entry?(entry1, entry2)
    end

    test "identifies different terms", %{entry1: entry1, entry3: entry3} do
      refute LogEntry.same_entry?(entry1, entry3)
    end

    test "identifies different indexes", %{entry1: entry1, entry4: entry4} do
      refute LogEntry.same_entry?(entry1, entry4)
    end
  end

  describe "more_recent_term?/2" do
    test "compares entry terms correctly" do
      {:ok, older} = LogEntry.new(1, 1, "old")
      {:ok, newer} = LogEntry.new(2, 2, "new")

      assert LogEntry.more_recent_term?(newer, older)
      refute LogEntry.more_recent_term?(older, newer)
    end
  end

  describe "is_next?/2" do
    test "identifies consecutive entries" do
      {:ok, entry1} = LogEntry.new(1, 1, "first")
      {:ok, entry2} = LogEntry.new(2, 1, "second")
      {:ok, entry3} = LogEntry.new(3, 1, "third")

      assert LogEntry.is_next?(entry1, entry2)
      assert LogEntry.is_next?(entry2, entry3)
      refute LogEntry.is_next?(entry1, entry3)
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "roundtrip serialization" do
      {:ok, original} = LogEntry.new(1, 1, %{action: "test"})
      serialized = LogEntry.serialize(original)
      {:ok, deserialized} = LogEntry.deserialize(serialized)

      assert deserialized.index == original.index
      assert deserialized.term == original.term
      assert deserialized.type == original.type
      assert deserialized.command == original.command

      # DateTime comparison should be within the same second
      original_unix = DateTime.to_unix(original.created_at)
      deserialized_unix = DateTime.to_unix(deserialized.created_at)
      assert abs(original_unix - deserialized_unix) <= 1
    end

    test "handles invalid deserialization data" do
      assert {:error, "Invalid entry data format"} =
        LogEntry.deserialize("invalid")
    end
  end
end
