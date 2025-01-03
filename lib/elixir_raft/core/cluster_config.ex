defmodule ElixirRaft.Core.ClusterConfig do
  @moduledoc """
  Manages cluster configuration and membership changes in Raft.

  Handles:
  - Current cluster membership
  - Configuration change transitions
  - Joint consensus during reconfigurations
  - Persistence of configuration state
  """

  alias ElixirRaft.Core.{NodeId, LogEntry, Term}

   @type node_id :: NodeId.t()
   @type config_state :: :stable | {:joint, MapSet.t(), MapSet.t()}

   @type t :: %__MODULE__{
     current_members: MapSet.t(),
     state: config_state(),
     config_index: non_neg_integer(),
     current_term: Term.t(),
     pending_members: MapSet.t(),
     removed_members: MapSet.t()
   }

   defstruct [
     :current_members,
     :state,
     :config_index,
     :current_term,
     pending_members: MapSet.new(),
     removed_members: MapSet.new()
   ]

  @doc """
  Creates a new cluster configuration with initial members.
  """
  @spec new([node_id()], Term.t()) :: {:ok, t()} | {:error, String.t()}
    def new(initial_members, initial_term \\ 0) when is_list(initial_members) do
      with :ok <- validate_members(initial_members) do
        config = %__MODULE__{
          current_members: MapSet.new(initial_members),
          state: :stable,
          config_index: 0,
          current_term: initial_term
        }
        {:ok, config}
      end
    end

  @doc """
  Starts a configuration change to add or remove nodes.
  Returns a new configuration entry to be added to the log.
  """
  @spec begin_change(t(), [node_id()], [node_id()]) ::
      {:ok, t(), LogEntry.t()} | {:error, String.t()}
    def begin_change(config, to_add, to_remove) do
      with :ok <- validate_change_request(config, to_add, to_remove),
           :ok <- validate_members(to_add ++ to_remove) do

        new_members = config.current_members
                     |> MapSet.union(MapSet.new(to_add))
                     |> MapSet.difference(MapSet.new(to_remove))

        if maintains_quorum?(new_members) do
          new_config = %{config |
            state: {:joint, config.current_members, new_members},
            pending_members: MapSet.new(to_add),
            removed_members: MapSet.new(to_remove)
          }

          entry = LogEntry.new!(
            config.config_index + 1,
            config.current_term,
            {:config_change, :begin, to_add, to_remove},
            type: :config_change
          )

          {:ok, new_config, entry}
        else
          {:error, "Configuration change would lose quorum capability"}
        end
      end
    end

  @doc """
  Commits a configuration change after joint consensus is reached.
  Returns a new configuration entry to be added to the log.
  """
  @spec commit_change(t()) :: {:ok, t(), LogEntry.t()} | {:error, String.t()}
    def commit_change(%__MODULE__{state: {:joint, _old, new}} = config) do
      new_config = %{config |
        current_members: new,
        state: :stable,
        pending_members: MapSet.new(),
        removed_members: MapSet.new(),
        config_index: config.config_index + 1
      }

      entry = LogEntry.new!(
        config.config_index + 1,
        config.current_term,
        {:config_change, :commit},
        type: :config_change
      )

      {:ok, new_config, entry}
    end

  def commit_change(%__MODULE__{state: :stable}),
    do: {:error, "No configuration change in progress"}

  @doc """
    Updates the current term in the configuration.
    """
    @spec update_term(t(), Term.t()) :: t()
    def update_term(config, new_term) do
      %{config | current_term: new_term}
    end

  @doc """
  Checks if a node is a current member of the cluster.
  """
  @spec is_member?(t(), node_id()) :: boolean()
  def is_member?(config, node_id) do
    case config.state do
      :stable ->
        MapSet.member?(config.current_members, node_id)
      {:joint, old, new} ->
        MapSet.member?(old, node_id) || MapSet.member?(new, node_id)
    end
  end

  @doc """
  Returns the current cluster size.
  During joint consensus, returns the size of the new configuration.
  """
  @spec cluster_size(t()) :: pos_integer()
  def cluster_size(%__MODULE__{state: :stable} = config) do
    MapSet.size(config.current_members)
  end

  def cluster_size(%__MODULE__{state: {:joint, _old, new}}) do
    MapSet.size(new)
  end

  @doc """
  Calculates the number of votes needed for quorum.
  During joint consensus, requires majority in both configurations.
  """
  @spec quorum_size(t()) :: pos_integer()
  def quorum_size(%__MODULE__{state: :stable} = config) do
    div(MapSet.size(config.current_members), 2) + 1
  end

  def quorum_size(%__MODULE__{state: {:joint, old, new}}) do
    [
      div(MapSet.size(old), 2) + 1,
      div(MapSet.size(new), 2) + 1
    ]
  end

  @doc """
  Checks if a set of nodes constitutes a quorum.
  During joint consensus, requires majority in both configurations.
  """
  @spec has_quorum?(t(), MapSet.t()) :: boolean()
  def has_quorum?(%__MODULE__{state: :stable} = config, nodes) do
    votes = MapSet.intersection(config.current_members, nodes)
    MapSet.size(votes) >= quorum_size(config)
  end

  def has_quorum?(%__MODULE__{state: {:joint, old, new}}, nodes) do
    old_votes = MapSet.intersection(old, nodes)
    new_votes = MapSet.intersection(new, nodes)

    MapSet.size(old_votes) >= div(MapSet.size(old), 2) + 1 &&
    MapSet.size(new_votes) >= div(MapSet.size(new), 2) + 1
  end

  # Private Functions

  defp validate_members([]), do: {:error, "Member list cannot be empty"}
  defp validate_members(members) do
    if Enum.all?(members, &is_binary/1) do
      :ok
    else
      {:error, "Invalid node ID format"}
    end
  end

  defp validate_change_request(config, to_add, to_remove) do
    cond do
      config.state != :stable ->
        {:error, "Configuration change already in progress"}

      Enum.any?(to_add, &MapSet.member?(config.current_members, &1)) ->
        {:error, "Cannot add existing member"}

      Enum.any?(to_remove, &(not MapSet.member?(config.current_members, &1))) ->
        {:error, "Cannot remove non-existent member"}

      MapSet.new(to_add)
      |> MapSet.intersection(MapSet.new(to_remove))
      |> MapSet.size() > 0 ->
        {:error, "Cannot add and remove the same node"}

      true ->
        :ok
    end
  end

  defp maintains_quorum?(members) do
    MapSet.size(members) >= 3 # Minimum size for fault tolerance
  end
end
