defmodule ElixirRaft.Network.PeerSupervisor do
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_peer(peer_config) do
    child_spec = %{
      id: ElixirRaft.Network.Peer,
      start: {ElixirRaft.Network.Peer, :start_link, [peer_config]},
      restart: :transient  # Don't restart if peer intentionally stops
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def stop_peer(peer_pid) when is_pid(peer_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, peer_pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 5
    )
  end
end
