defmodule ElixirRaft.Core.ClusterInfo do
  @moduledoc """
  Helper module for cluster configuration and peer management
  """

  @doc """
  Gets all peer node IDs except the given node
  """
  def get_peer_ids(except_node_id) do
    peers = Application.get_env(:elixir_raft, :peers, %{})
    peers
    |> Map.keys()
    |> Enum.reject(fn node_id -> node_id == except_node_id end)
  end

  @doc """
  Gets the address for a given node ID
  """
  def get_node_address(node_id) do
    peers = Application.get_env(:elixir_raft, :peers, %{})
    Map.get(peers, node_id)
  end

  @doc """
  Gets the cluster size
  """
  def cluster_size do
    Application.get_env(:elixir_raft, :cluster_size, 3)
  end

  @doc """
  Calculates the number of votes needed for majority
  """
  def majority_size do
    div(cluster_size(), 2) + 1
  end
end
