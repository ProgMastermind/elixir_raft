defmodule ElixirRaft.Network.TransportBehaviour do
  @moduledoc """
  Defines the behaviour that any transport implementation must follow.
  This abstraction allows for different transport mechanisms (TCP, UDP, etc.)
  while maintaining a consistent interface for the Raft implementation.
  """

  alias ElixirRaft.Core.NodeId

  @type address :: {:inet.ip_address(), :inet.port_number()}
  @type transport_options :: keyword()
  @type error_reason :: term()

  @doc """
  Start the transport layer.
  """
  @callback start_link(transport_options()) ::
              {:ok, pid()} | {:error, error_reason()}

  @doc """
  Listen for incoming connections.
  Returns the address the transport is listening on.
  """
  @callback listen(pid(), transport_options()) ::
              {:ok, address()} | {:error, error_reason()}

  @doc """
  Connect to a remote node.
  """
  @callback connect(pid(), NodeId.t(), address(), transport_options()) ::
              {:ok, port()} | {:error, error_reason()}

  @doc """
  Send a message to a connected peer.
  """
  @callback send(pid(), port(), binary()) ::
              :ok | {:error, error_reason()}

  @doc """
  Close a specific connection.
  """
  @callback close_connection(pid(), port()) :: :ok

  @doc """
  Stop the transport layer.
  """
  @callback stop(pid()) :: :ok

  @doc """
  Get the local address that the transport is bound to.
  """
  @callback get_local_address(pid()) ::
              {:ok, address()} | {:error, error_reason()}

  @doc """
  Register a message handler function.
  The handler will be called with (peer_id, message) for each received message.
  """
  @callback register_message_handler(pid(), (NodeId.t(), binary() -> any())) ::
              :ok

  @doc """
  Get the current connection status for a peer.
  """
  @callback connection_status(pid(), NodeId.t()) ::
              :connected | :connecting | :disconnected

  @optional_callbacks [
    connection_status: 2
  ]
end
