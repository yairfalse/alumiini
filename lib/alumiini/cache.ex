defmodule Alumiini.Cache do
  @moduledoc """
  ETS-based caching for ALUMIINI.

  Provides in-memory storage for:
  - Commit hashes per repository
  - Resource hashes for drift detection
  - Sync state tracking

  No external dependencies (Redis, database).
  Cache survives process crashes when stored in separate process.
  """

  use GenServer
  require Logger

  @commits_table :alumiini_commits
  @resources_table :alumiini_resources
  @sync_states_table :alumiini_sync_states

  # Client API

  @doc """
  Starts the cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a commit hash for a repository.
  """
  @spec put_commit(String.t(), String.t()) :: :ok
  def put_commit(repo_name, commit) do
    :ets.insert(@commits_table, {repo_name, commit, DateTime.utc_now()})
    :ok
  end

  @doc """
  Retrieves the cached commit hash for a repository.
  """
  @spec get_commit(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_commit(repo_name) do
    case :ets.lookup(@commits_table, repo_name) do
      [{^repo_name, commit, _timestamp}] -> {:ok, commit}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Deletes the cached commit hash for a repository.
  """
  @spec delete_commit(String.t()) :: :ok
  def delete_commit(repo_name) do
    :ets.delete(@commits_table, repo_name)
    :ok
  end

  @doc """
  Stores a resource hash for drift detection.
  """
  @spec put_resource_hash(String.t(), String.t(), String.t()) :: :ok
  def put_resource_hash(repo_name, resource_key, hash) do
    :ets.insert(@resources_table, {{repo_name, resource_key}, hash})
    :ok
  end

  @doc """
  Retrieves a cached resource hash.
  """
  @spec get_resource_hash(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_resource_hash(repo_name, resource_key) do
    case :ets.lookup(@resources_table, {repo_name, resource_key}) do
      [{{^repo_name, ^resource_key}, hash}] -> {:ok, hash}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all resource hashes for a repository.
  """
  @spec list_resource_hashes(String.t()) :: [{String.t(), String.t()}]
  def list_resource_hashes(repo_name) do
    @resources_table
    |> :ets.match({{repo_name, :"$1"}, :"$2"})
    |> Enum.map(fn [key, hash] -> {key, hash} end)
  end

  @doc """
  Clears all resource hashes for a repository.
  """
  @spec clear_resource_hashes(String.t()) :: :ok
  def clear_resource_hashes(repo_name) do
    @resources_table
    |> :ets.match({{repo_name, :"$1"}, :_})
    |> Enum.each(fn [key] ->
      :ets.delete(@resources_table, {repo_name, key})
    end)

    :ok
  end

  @doc """
  Stores sync state for a repository.
  """
  @spec put_sync_state(String.t(), map()) :: :ok
  def put_sync_state(repo_name, state) do
    :ets.insert(@sync_states_table, {repo_name, state})
    :ok
  end

  @doc """
  Retrieves sync state for a repository.
  """
  @spec get_sync_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_sync_state(repo_name) do
    case :ets.lookup(@sync_states_table, repo_name) do
      [{^repo_name, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables with public access (other processes can read/write)
    :ets.new(@commits_table, [:set, :public, :named_table])
    :ets.new(@resources_table, [:set, :public, :named_table])
    :ets.new(@sync_states_table, [:set, :public, :named_table])

    Logger.info("Cache started with ETS tables: commits, resources, sync_states")

    {:ok, %{}}
  end
end
