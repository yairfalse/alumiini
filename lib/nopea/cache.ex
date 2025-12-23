defmodule Nopea.Cache do
  @moduledoc """
  ETS-based caching for NOPEA.

  Provides in-memory storage for:
  - Commit hashes per repository
  - Resource hashes for drift detection
  - Sync state tracking

  No external dependencies (Redis, database).
  Cache survives process crashes when stored in separate process.
  """

  use GenServer
  require Logger

  @commits_table :nopea_commits
  @resources_table :nopea_resources
  @sync_states_table :nopea_sync_states
  @last_applied_table :nopea_last_applied

  # Client API

  @doc """
  Checks if the Cache is available (tables exist).

  Returns `true` if Cache is running and tables are accessible.
  """
  @spec available?() :: boolean()
  def available? do
    :ets.whereis(@commits_table) != :undefined
  end

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

  # ── Last Applied Manifests (for three-way drift detection) ─────────────────

  @doc """
  Stores the last-applied manifest for a resource.

  Used for three-way drift detection. The manifest should be normalized
  (K8s-managed fields stripped) before storing.
  """
  @spec put_last_applied(String.t(), String.t(), map()) :: :ok
  def put_last_applied(repo_name, resource_key, manifest) do
    :ets.insert(@last_applied_table, {{repo_name, resource_key}, manifest, DateTime.utc_now()})
    :ok
  end

  @doc """
  Retrieves the last-applied manifest for a resource.
  """
  @spec get_last_applied(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_last_applied(repo_name, resource_key) do
    case :ets.lookup(@last_applied_table, {repo_name, resource_key}) do
      [{{^repo_name, ^resource_key}, manifest, _timestamp}] -> {:ok, manifest}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all last-applied manifests for a repository.

  Returns a list of `{resource_key, manifest}` tuples.
  """
  @spec list_last_applied(String.t()) :: [{String.t(), map()}]
  def list_last_applied(repo_name) do
    @last_applied_table
    |> :ets.match({{repo_name, :"$1"}, :"$2", :_})
    |> Enum.map(fn [key, manifest] -> {key, manifest} end)
  end

  @doc """
  Clears all last-applied manifests for a repository.
  """
  @spec clear_last_applied(String.t()) :: :ok
  def clear_last_applied(repo_name) do
    @last_applied_table
    |> :ets.match({{repo_name, :"$1"}, :_, :_})
    |> Enum.each(fn [key] ->
      :ets.delete(@last_applied_table, {repo_name, key})
    end)

    :ok
  end

  @doc """
  Deletes a specific last-applied manifest.
  """
  @spec delete_last_applied(String.t(), String.t()) :: :ok
  def delete_last_applied(repo_name, resource_key) do
    :ets.delete(@last_applied_table, {repo_name, resource_key})
    :ok
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables with public access (other processes can read/write)
    :ets.new(@commits_table, [:set, :public, :named_table])
    :ets.new(@resources_table, [:set, :public, :named_table])
    :ets.new(@sync_states_table, [:set, :public, :named_table])
    :ets.new(@last_applied_table, [:set, :public, :named_table])

    Logger.info("Cache started with ETS tables: commits, resources, sync_states, last_applied")

    {:ok, %{}}
  end
end
