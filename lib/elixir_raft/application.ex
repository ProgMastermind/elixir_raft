defmodule ElixirRaft.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:elixir_raft, :node_config, [])

        children = [
          # TCP Transport Supervisor
          {ElixirRaft.Network.TcpTransport.Supervisor, config},
          # Other supervisors will be added later
        ]

        opts = [strategy: :one_for_one, name: ElixirRaft.Supervisor]
        Supervisor.start_link(children, opts)
  end
end
