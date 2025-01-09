defmodule ElixirRaft.Server.RoleBehaviour do
  @moduledoc """
  Defines the behavior that all Raft roles must implement.
  """

  alias ElixirRaft.Core.ServerState

  @callback init(ServerState.t()) ::
    {:ok, term()} |
    {:ok, term(), term()}  # state and broadcast message

  @callback handle_append_entries(term(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:ok, ServerState.t(), term(), term()} |  # with response
    {:transition, atom(), ServerState.t()}

  @callback handle_append_entries_response(term(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:transition, atom(), ServerState.t()}

  @callback handle_request_vote(term(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:ok, ServerState.t(), term(), term()} |  # with response
    {:transition, atom(), ServerState.t()}

  @callback handle_request_vote_response(term(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:transition, atom(), ServerState.t()}

  @callback handle_timeout(atom(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:transition, atom(), ServerState.t()}

  @callback handle_client_command(term(), ServerState.t(), term()) ::
    {:ok, ServerState.t(), term()} |
    {:error, term()} |
    {:redirect, NodeId.t()}
end
