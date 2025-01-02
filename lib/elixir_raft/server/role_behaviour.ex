defmodule ElixirRaft.Server.RoleBehaviour do
  @moduledoc """
  Defines the behavior that all Raft roles (Follower, Candidate, Leader) must implement.
  This ensures consistent handling of events across roles according to the Raft spec.
  """

  alias ElixirRaft.Core.{ServerState}
  alias ElixirRaft.RPC.Messages.{RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse}

  @type role_state :: term()
  @type handler_response :: {:ok, ServerState.t(), role_state()} |
                           {:transition, atom(), ServerState.t(), role_state()} |
                           {:error, String.t()}

  @callback init(ServerState.t()) :: {:ok, role_state()}

  @callback handle_append_entries(AppendEntries.t(), ServerState.t(), role_state()) ::
    handler_response()

  @callback handle_append_entries_response(AppendEntriesResponse.t(), ServerState.t(), role_state()) ::
    handler_response()

  @callback handle_request_vote(RequestVote.t(), ServerState.t(), role_state()) ::
    handler_response()

  @callback handle_request_vote_response(RequestVoteResponse.t(), ServerState.t(), role_state()) ::
    handler_response()

  @callback handle_timeout(atom(), ServerState.t(), role_state()) ::
    handler_response()

  @callback handle_client_command(term(), ServerState.t(), role_state()) ::
    handler_response()
end
