defmodule Alumiini.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing Worker processes.

  One Worker per GitRepository resource.
  Automatic restart on crash.
  """

  use DynamicSupervisor
  require Logger

  alias Alumiini.Worker

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Supervisor started")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a worker for the given repository config.
  """
  @spec start_worker(map()) :: {:ok, pid()} | {:error, term()}
  def start_worker(config) do
    child_spec = {Worker, config}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started worker for repo: #{config.name}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, reason} = error ->
        Logger.error("Failed to start worker for repo #{config.name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops the worker for the given repository name.
  """
  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(repo_name) do
    case Worker.whereis(repo_name) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.info("Stopped worker for repo: #{repo_name}")
        :ok
    end
  end

  @doc """
  Lists all active workers.
  Returns list of {repo_name, pid} tuples.
  """
  @spec list_workers() :: [{String.t(), pid()}]
  def list_workers do
    Registry.select(Alumiini.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Gets the pid for a worker by repo name.
  """
  @spec get_worker(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_worker(repo_name) do
    case Worker.whereis(repo_name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end
end
