defmodule Alumiini.Worker do
  @moduledoc """
  GenServer worker for a single GitRepository.

  Responsibilities:
  - Git clone/fetch operations
  - Periodic polling
  - Webhook handling
  - Drift detection
  - K8s apply operations
  """

  use GenServer
  require Logger

  alias Alumiini.Cache

  defstruct [
    :config,
    :poll_timer,
    :reconcile_timer,
    :last_commit,
    :last_sync,
    status: :initializing
  ]

  @type status :: :initializing | :syncing | :synced | :failed | :drifted

  @type t :: %__MODULE__{
          config: map(),
          poll_timer: reference() | nil,
          reconcile_timer: reference() | nil,
          last_commit: String.t() | nil,
          last_sync: DateTime.t() | nil,
          status: status()
        }

  # Client API

  @doc """
  Starts a worker with the given config.
  """
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config.name))
  end

  @doc """
  Returns the current state of a worker.
  """
  @spec get_state(pid()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Triggers an immediate sync.
  """
  @spec sync_now(pid()) :: :ok | {:error, term()}
  def sync_now(pid) do
    GenServer.call(pid, :sync_now, 30_000)
  end

  @doc """
  Looks up a worker by repo name.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(repo_name) do
    case Registry.lookup(Alumiini.Registry, repo_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Private helper for via tuple
  defp via_tuple(repo_name) do
    {:via, Registry, {Alumiini.Registry, repo_name}}
  end

  # Server Callbacks

  @impl true
  def init(config) do
    Logger.info("Worker starting for repo: #{config.name}")

    state = %__MODULE__{
      config: config,
      status: :initializing
    }

    # Schedule initial sync
    send(self(), :startup_sync)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    case do_sync(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("Sync failed for #{state.config.name}: #{inspect(reason)}")
        {:reply, error, %{state | status: :failed}}
    end
  end

  @impl true
  def handle_info(:startup_sync, state) do
    Logger.info("Performing startup sync for: #{state.config.name}")

    new_state =
      case do_sync(state) do
        {:ok, synced_state} ->
          schedule_poll(synced_state)
          schedule_reconcile(synced_state)
          synced_state

        {:error, reason} ->
          Logger.warning("Startup sync failed for #{state.config.name}: #{inspect(reason)}")
          schedule_poll(state)
          %{state | status: :failed}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    Logger.debug("Poll triggered for: #{state.config.name}")

    new_state =
      case check_for_changes(state) do
        {:changed, commit} ->
          Logger.info("Changes detected for #{state.config.name}, commit: #{commit}")

          case do_sync(state) do
            {:ok, synced_state} -> synced_state
            {:error, _} -> %{state | status: :failed}
          end

        :unchanged ->
          state
      end

    {:noreply, schedule_poll(new_state)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("Reconcile triggered for: #{state.config.name}")

    new_state =
      case detect_drift(state) do
        {:drifted, _resources} ->
          Logger.warning("Drift detected for #{state.config.name}")

          case do_sync(state) do
            {:ok, synced_state} -> %{synced_state | status: :synced}
            {:error, _} -> %{state | status: :drifted}
          end

        :in_sync ->
          state
      end

    {:noreply, schedule_reconcile(new_state)}
  end

  @impl true
  def handle_info({:webhook, commit}, state) do
    Logger.info("Webhook received for #{state.config.name}, commit: #{commit}")

    new_state =
      case do_sync(state) do
        {:ok, synced_state} -> synced_state
        {:error, _} -> %{state | status: :failed}
      end

    {:noreply, new_state}
  end

  # Private functions

  defp do_sync(state) do
    # TODO: Implement actual git clone/fetch and K8s apply
    # For now, just update state
    Logger.info("Syncing repo: #{state.config.name}")

    new_state = %{
      state
      | status: :synced,
        last_sync: DateTime.utc_now()
    }

    # Update cache
    Cache.put_sync_state(state.config.name, %{
      last_sync: new_state.last_sync,
      status: new_state.status
    })

    {:ok, new_state}
  end

  defp check_for_changes(_state) do
    # TODO: Implement git fetch and compare HEAD
    :unchanged
  end

  defp detect_drift(_state) do
    # TODO: Compare cached resource hashes with K8s actual state
    :in_sync
  end

  defp schedule_poll(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, state.config.interval)
    %{state | poll_timer: timer}
  end

  defp schedule_reconcile(state) do
    if state.reconcile_timer, do: Process.cancel_timer(state.reconcile_timer)
    # Reconcile less frequently than poll (2x interval)
    timer = Process.send_after(self(), :reconcile, state.config.interval * 2)
    %{state | reconcile_timer: timer}
  end
end
