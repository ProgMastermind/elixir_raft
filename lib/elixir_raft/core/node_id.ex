defmodule ElixirRaft.Core.NodeId do
  @moduledoc """
  Manages node identification in the Raft cluster.
  Ensures uniqueness and proper formatting of node IDs.
  """

  @type t :: String.t()

  @doc """
  Generates a new unique node ID.
  """
  @spec generate() :: t()
  def generate do
    UUID.uuid4()
  end

  @doc """
  Validates a node ID format.
  Returns {:ok, node_id} if valid, {:error, reason} if invalid.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(node_id) when is_binary(node_id) do
    case UUID.info(node_id) do
      {:ok, _info} -> {:ok, node_id}
      {:error, _reason} -> {:error, "Invalid node ID format"}
    end
  end

  def validate(_), do: {:error, "Node ID must be a string"}

  @doc """
  Validates a node ID and raises an error if invalid.
  """
  @spec validate!(term()) :: t() | no_return()
  def validate!(node_id) do
    case validate(node_id) do
      {:ok, valid_id} -> valid_id
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  @doc """
  Compares two node IDs.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(node_id1, node_id2) when is_binary(node_id1) and is_binary(node_id2) do
      cond do
        node_id1 < node_id2 -> :lt
        node_id1 > node_id2 -> :gt
        true -> :eq
      end
    end
end
