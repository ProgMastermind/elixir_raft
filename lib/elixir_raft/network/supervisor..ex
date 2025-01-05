defmodule ElixirRaft.Network.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      # TCP Transport and its connections
            {ElixirRaft.Network.TcpTransport, opts},
            # Peer management
            {ElixirRaft.Network.PeerSupervisor, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
