defmodule ElixirRaft.TestSupport.ClusterHelper do
  @moduledoc """
  Helper functions for testing Raft cluster behavior
  """

  require Logger

  @doc """
  Waits for a leader to be elected in the cluster
  """
  def wait_for_leader(nodes, timeout \\ 5000) do
    start_time = System.monotonic_time(:millisecond)

    wait_for_condition(
      fn ->
        leaders = get_leaders(nodes)
        case leaders do
          [leader] -> {:ok, leader}
          [] -> {:error, :no_leader}
          leaders -> {:error, {:multiple_leaders, leaders}}
        end
      end,
      timeout,
      start_time
    )
  end

  @doc """
  Gets all current leaders in the cluster
  """
  def get_leaders(nodes) do
    nodes
    |> Enum.filter(fn {_id, pid} ->
      {:ok, role} = MessageDispatcher.get_current_role(pid)
      role == :leader
    end)
  end

  # Private helpers

  defp wait_for_condition(condition_fn, timeout, start_time) do
    case condition_fn.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        current_time = System.monotonic_time(:millisecond)
        elapsed = current_time - start_time

        if elapsed > timeout do
          {:error, {:timeout, reason}}
        else
          Process.sleep(100)
          wait_for_condition(condition_fn, timeout, start_time)
        end
    end
  end
end
