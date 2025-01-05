defmodule ElixirRaft.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
      # Don't start supervision tree in test environment
      if Mix.env() == :test do
        Supervisor.start_link([], strategy: :one_for_one, name: ElixirRaft.Supervisor)
      else
        config = Application.get_env(:elixir_raft, :node_config, [])

        children = [
          # {ElixirRaft.Network.Supervisor, config}
        ]

        opts = [strategy: :one_for_one, name: ElixirRaft.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
end
