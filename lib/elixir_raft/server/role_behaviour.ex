defmodule ElixirRaft.Server.RoleBehaviour do
  @moduledoc """
  Defines the behavior that all Raft server roles must implement.
  This includes handling RPCs and timeouts according to the Raft consensus algorithm.
  """

  alias ElixirRaft.Core.{Term, NodeId}
   alias ElixirRaft.RPC.Messages.{RequestVote, RequestVoteResponse, AppendEntries, AppendEntriesResponse}

   @type server_role :: :follower | :candidate | :leader
   @type rpc_message :: RequestVote.t() | RequestVoteResponse.t() | AppendEntries.t() | AppendEntriesResponse.t()
   @type role_state :: term()
   @type role_reply :: {:ok, role_state()} | {:transition, server_role(), role_state()}
   @type timer_type :: :election | :heartbeat
   @type log_index :: non_neg_integer()

  @doc """
  Initializes the role's state.
  """
  @callback init(NodeId.t(), Term.t()) :: {:ok, role_state()}

  @doc """
  Handles incoming RPC messages.
  Returns updated state and optionally triggers role transition.
  """
  @callback handle_rpc(rpc_message(), role_state()) :: role_reply()

  @doc """
  Handles timer events (election timeout, heartbeat timeout).
  """
  @callback handle_timeout(timer_type(), role_state()) :: role_reply()

  @doc """
  Handles client commands (only meaningful for leader).
  """
  @callback handle_command(term(), role_state()) ::
    {:ok, log_index(), role_state()} |
    {:error, :not_leader, role_state()} |
    {:transition, server_role(), role_state()}

  @doc """
  Returns the current role's type.
  """
  @callback role_type() :: server_role()

  @doc """
  Returns the timers that should be active for this role.
  """
  @callback active_timers() :: [timer_type()]
end
