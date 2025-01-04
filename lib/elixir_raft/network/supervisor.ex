defmodule ElixirRaft.Network.TcpTransport.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {ElixirRaft.Network.TcpTransport, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
