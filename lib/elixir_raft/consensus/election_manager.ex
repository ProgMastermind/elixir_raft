defmodule ElixirRaft.Consensus.ElectionManager do
  @moduledoc """
  Manages election-related aspects of the Raft consensus protocol:
  - Election timeouts
  - Vote counting
  - Leader election state
  - Vote request/response handling
  """

  use GenServer
    require Logger

    alias ElixirRaft.Core.{Term, NodeId}

    @min_timeout 150
    @max_timeout 300


  defmodule State do
    @moduledoc false
    defstruct [
      :node_id,
      :current_term,
      :voted_for,
      :election_timer_ref,
      :election_timeout,
      :cluster_size,
      :quorum_size,
      votes_received: MapSet.new(),
      election_state: :follower,  # :follower, :candidate, or :leader
      leader_id: nil,
      last_leader_contact: nil
    ]
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_from_opts(opts))
  end

  @spec record_vote(GenServer.server(), NodeId.t(), boolean(), Term.t()) ::
    {:ok, :elected | :not_elected} | {:error, term()}
  def record_vote(server, voter_id, vote_granted, term) do
    GenServer.call(server, {:record_vote, voter_id, vote_granted, term})
  end

  @spec start_election(GenServer.server()) :: :ok | {:error, term()}
  def start_election(server) do
    GenServer.cast(server, :start_election)
  end

  @spec step_down(GenServer.server(), Term.t()) :: :ok
  def step_down(server, term) do
    GenServer.cast(server, {:step_down, term})
  end

  @spec record_leader_contact(GenServer.server(), NodeId.t(), Term.t()) :: :ok
  def record_leader_contact(server, leader_id, term) do
    GenServer.cast(server, {:leader_contact, leader_id, term})
  end

  @spec get_leader(GenServer.server()) :: {:ok, NodeId.t() | nil}
  def get_leader(server) do
    GenServer.call(server, :get_leader)
  end

  @spec get_current_term(GenServer.server()) :: {:ok, Term.t()}
  def get_current_term(server) do
    GenServer.call(server, :get_current_term)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    with {:ok, node_id} <- Keyword.fetch(opts, :node_id),
         {:ok, cluster_size} <- Keyword.fetch(opts, :cluster_size),
         {:ok, current_term} <- Keyword.fetch(opts, :current_term) do

      state = %State{
        node_id: node_id,
        current_term: current_term,
        voted_for: nil,
        cluster_size: cluster_size,
        quorum_size: div(cluster_size, 2) + 1,
        election_timeout: random_timeout(),
        election_state: :follower
      }

      {:ok, schedule_election_timeout(state)}
    else
      :error -> {:stop, :missing_required_options}
    end
  end

  @impl true
  def handle_call({:record_vote, voter_id, vote_granted, term}, _from, state) do
    cond do
      term != state.current_term ->
        {:reply, {:error, :term_mismatch}, state}

      state.election_state != :candidate ->
        {:reply, {:error, :not_candidate}, state}

      true ->
        handle_vote_response(voter_id, vote_granted, state)
    end
  end

  def handle_call(:get_leader, _from, state) do
    {:reply, {:ok, state.leader_id}, state}
  end

  def handle_call(:get_current_term, _from, state) do
    {:reply, {:ok, state.current_term}, state}
  end

  @impl true
  def handle_cast(:start_election, state) do
    new_state = start_new_election(state)
    {:noreply, new_state}
  end

  def handle_cast({:step_down, term}, state) do
    if term >= state.current_term do
      new_state = %{state |
        current_term: term,
        election_state: :follower,
        voted_for: nil,
        leader_id: nil,
        votes_received: MapSet.new()
      }
      {:noreply, schedule_election_timeout(new_state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:leader_contact, leader_id, term}, state) do
    if term >= state.current_term do
      new_state = %{state |
        current_term: term,
        leader_id: leader_id,
        last_leader_contact: System.monotonic_time(:millisecond),
        election_state: :follower
      }
      {:noreply, schedule_election_timeout(new_state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:election_timeout, state) do
    case state.election_state do
      :follower ->
        new_state = start_new_election(state)
        {:noreply, new_state}

      :candidate ->
        new_state = start_new_election(state)
        {:noreply, new_state}

      :leader ->
        {:noreply, state}
    end
  end

  # Private Functions

  defp handle_vote_response(voter_id, true, state) do
    new_votes = MapSet.put(state.votes_received, voter_id)
    new_state = %{state | votes_received: new_votes}

    if MapSet.size(new_votes) >= state.quorum_size do
      {:reply, {:ok, :elected}, become_leader(new_state)}
    else
      {:reply, {:ok, :not_elected}, new_state}
    end
  end

  defp handle_vote_response(_voter_id, false, state) do
    {:reply, {:ok, :not_elected}, state}
  end

  defp start_new_election(state) do
    new_term = state.current_term + 1

    %{state |
      current_term: new_term,
      election_state: :candidate,
      voted_for: state.node_id,
      votes_received: MapSet.new([state.node_id]),
      leader_id: nil,
      election_timeout: random_timeout()
    }
    |> schedule_election_timeout()
  end

  defp become_leader(state) do
    %{state |
      election_state: :leader,
      leader_id: state.node_id,
      election_timer_ref: nil
    }
  end

  defp schedule_election_timeout(state) do
    if state.election_timer_ref, do: Process.cancel_timer(state.election_timer_ref)

    timer_ref = Process.send_after(
      self(),
      :election_timeout,
      state.election_timeout
    )

    %{state | election_timer_ref: timer_ref}
  end

  defp random_timeout do
    @min_timeout + :rand.uniform(@max_timeout - @min_timeout)
  end

  defp name_from_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> __MODULE__
      name -> name
    end
  end
end
