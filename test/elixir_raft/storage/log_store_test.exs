defmodule ElixirRaft.Storage.LogStoreTest do
  use ExUnit.Case, async: false  # Not async due to file system operations
  alias ElixirRaft.Storage.LogStore
  alias ElixirRaft.Core.LogEntry

  @test_dir "test/tmp/log_store"

  setup do
    # Clean up test directory before each test
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Start a log store
    {:ok, store} = LogStore.start_link(data_dir: @test_dir, sync_writes: true)

    # Cleanup after test
    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    {:ok, store: store}
  end

  describe "append/2" do
    test "appends entries in sequence", %{store: store} do
      {:ok, entry1} = LogEntry.new(1, 1, "command1")
      {:ok, entry2} = LogEntry.new(2, 1, "command2")

      assert {:ok, 1} = LogStore.append(store, entry1)
      assert {:ok, 2} = LogStore.append(store, entry2)
    end

    test "rejects out of sequence entries", %{store: store} do
      {:ok, entry1} = LogEntry.new(2, 1, "command1")
      assert {:error, _} = LogStore.append(store, entry1)
    end

    test "rejects entries with decreasing terms", %{store: store} do
      {:ok, entry1} = LogEntry.new(1, 2, "command1")
      {:ok, entry2} = LogEntry.new(2, 1, "command2")

      assert {:ok, 1} = LogStore.append(store, entry1)
      assert {:error, _} = LogStore.append(store, entry2)
    end
  end

  describe "get_entry/2" do
    test "retrieves existing entries", %{store: store} do
      {:ok, entry} = LogEntry.new(1, 1, "command1")
      {:ok, 1} = LogStore.append(store, entry)

      assert {:ok, retrieved} = LogStore.get_entry(store, 1)
      assert retrieved.command == "command1"
    end

    test "returns error for non-existent entries", %{store: store} do
      assert {:error, :not_found} = LogStore.get_entry(store, 1)
    end
  end

  describe "get_entries/3" do
    test "retrieves range of entries", %{store: store} do
      _entries = for n <- 1..3 do
        {:ok, entry} = LogEntry.new(n, 1, "command#{n}")
        {:ok, _} = LogStore.append(store, entry)
        entry
      end

      assert {:ok, retrieved} = LogStore.get_entries(store, 1, 3)
      assert length(retrieved) == 3
      assert Enum.map(retrieved, & &1.command) == ["command1", "command2", "command3"]
    end

    test "handles partial ranges", %{store: store} do
      {:ok, entry} = LogEntry.new(1, 1, "command1")
      {:ok, 1} = LogStore.append(store, entry)

      assert {:ok, retrieved} = LogStore.get_entries(store, 1, 3)
      assert length(retrieved) == 1
    end
  end

  describe "truncate_after/2" do
    test "truncates log at specified index", %{store: store} do
      # Append entries
      for n <- 1..3 do
        {:ok, entry} = LogEntry.new(n, 1, "command#{n}")
        {:ok, _} = LogStore.append(store, entry)
      end

      # Truncate after index 2
      assert :ok = LogStore.truncate_after(store, 2)

      # Verify remaining entries
      assert {:ok, entries} = LogStore.get_entries(store, 1, 3)
      assert length(entries) == 2
      assert Enum.map(entries, & &1.command) == ["command1", "command2"]
    end

    test "rejects invalid truncate index", %{store: store} do
      assert {:error, _} = LogStore.truncate_after(store, -1)
    end
  end

  describe "get_last_entry_info/1" do
    test "returns correct last entry info", %{store: store} do
      for n <- 1..3 do
        {:ok, entry} = LogEntry.new(n, n, "command#{n}")
        {:ok, _} = LogStore.append(store, entry)
      end

      assert {:ok, {3, 3}} = LogStore.get_last_entry_info(store)
    end

    test "handles empty log", %{store: store} do
      assert {:ok, {0, 0}} = LogStore.get_last_entry_info(store)
    end
  end

  describe "persistence" do
    test "recovers state after restart", %{store: store} do
      # Append some entries
      for n <- 1..3 do
        {:ok, entry} = LogEntry.new(n, 1, "command#{n}")
        {:ok, _} = LogStore.append(store, entry)
      end

      # Stop the store
      GenServer.stop(store)

      # Start a new store with the same directory
      {:ok, store2} = LogStore.start_link(data_dir: @test_dir, sync_writes: true)

      # Verify entries were recovered
      assert {:ok, entries} = LogStore.get_entries(store2, 1, 3)
      assert length(entries) == 3
      assert Enum.map(entries, & &1.command) == ["command1", "command2", "command3"]
    end
  end
end
