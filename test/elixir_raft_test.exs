defmodule ElixirRaftTest do
  use ExUnit.Case
  doctest ElixirRaft

  test "greets the world" do
    assert ElixirRaft.hello() == :world
  end
end
