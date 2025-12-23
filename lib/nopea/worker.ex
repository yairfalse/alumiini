defmodule Nopea.Worker do
  @moduledoc """
  GenServer worker for a single GitRepository.

  Responsibilities:
  - Git clone/fetch operations via Rust Port
  - Periodic polling for changes
  - Webhook handling
  - K8s apply operations
  - Status updates to GitRepository CRD
  """

  use GenServer
  require Logger

  alias Nopea.{Cache, Git, K8s, Applier, Events}
  alias Nopea.Events.Emitter

  defstruct [
    :config,
    :poll_timer,
    :reconcile_timer,
    :last_commit,
    :last_sync,
    status: :initializing
  ]

  @type status :: :initializing | :syncing | :synced | :failed

  @type t :: %__MODULE__{
          config: map(),
          poll_timer: reference() | nil,
          reconcile_timer: reference() | nil,
          last_commit: String.t() | nil,
          last_sync: DateTime.t() | nil,
          status: status()
        }

  @repo_base_path "/tmp/nopea/repos"

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
    GenServer.call(pid, :sync_now, 300_000)
  end

  @doc """
  Looks up a worker by repo name.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(repo_name) do
    case Registry.lookup(Nopea.Registry, repo_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Private helper for via tuple
  defp via_tuple(repo_name) do
    {:via, Registry, {Nopea.Registry, repo_name}}
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
          update_crd_status(state, :failed, "Startup sync failed: #{inspect(reason)}")
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

    # Re-apply manifests to fix any drift
    new_state =
      case apply_manifests(state) do
        {:ok, _count} ->
          %{state | status: :synced}

        {:error, reason} ->
          Logger.warning("Reconcile apply failed for #{state.config.name}: #{inspect(reason)}")
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
    config = state.config
    repo_path = repo_path(config.name)
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Syncing repo: #{config.name} from #{config.url}")
    update_crd_status(state, :syncing, "Syncing from git")

    with {:ok, commit_sha} <- Git.sync(config.url, config.branch, repo_path),
         {:ok, count} <- apply_manifests_from_repo(state, repo_path) do
      now = DateTime.utc_now()
      duration_ms = System.monotonic_time(:millisecond) - start_time

      new_state = %{
        state
        | status: :synced,
          last_commit: commit_sha,
          last_sync: now
      }

      # Update cache if available
      if Cache.available?() do
        Cache.put_sync_state(config.name, %{
          last_sync: now,
          last_commit: commit_sha,
          status: :synced
        })
      end

      # Update CRD status
      update_crd_status(new_state, :synced, "Applied #{count} manifests")

      # Emit CDEvent
      emit_sync_event(state, new_state, count, duration_ms)

      Logger.info("Sync completed for #{config.name}: commit=#{commit_sha}, manifests=#{count}")
      {:ok, new_state}
    else
      {:error, reason} = error ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        Logger.error("Sync failed for #{config.name}: #{inspect(reason)}")
        update_crd_status(state, :failed, "Sync failed: #{inspect(reason)}")

        # Emit failure CDEvent
        emit_failure_event(state, reason, duration_ms)

        error
    end
  end

  defp apply_manifests_from_repo(state, repo_path) do
    config = state.config
    manifest_path = if config.path, do: Path.join(repo_path, config.path), else: repo_path

    with {:ok, files} <- list_manifest_files(repo_path, config.path),
         {:ok, manifests} <- read_and_parse_manifests(repo_path, config.path, files) do
      Logger.info("Found #{length(manifests)} manifests in #{manifest_path}")
      K8s.apply_manifests(manifests, config.target_namespace)
    end
  end

  defp apply_manifests(state) do
    config = state.config
    repo_path = repo_path(config.name)

    if File.exists?(repo_path) do
      apply_manifests_from_repo(state, repo_path)
    else
      {:error, :repo_not_cloned}
    end
  end

  defp list_manifest_files(repo_path, subpath) do
    case Git.files(repo_path, subpath) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:list_files_failed, reason}}
    end
  end

  defp read_and_parse_manifests(repo_path, subpath, files) do
    results =
      Enum.map(files, fn file ->
        file_path = if subpath, do: Path.join(subpath, file), else: file

        with {:ok, base64_content} <- Git.read(repo_path, file_path),
             {:ok, content} <- Git.decode_content(base64_content),
             {:ok, manifests} <- Applier.parse_manifests(content) do
          {:ok, manifests}
        else
          {:error, reason} -> {:error, {file, reason}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      manifests =
        results
        |> Enum.flat_map(fn {:ok, m} -> m end)

      {:ok, manifests}
    else
      {:error, {:parse_failed, errors}}
    end
  end

  defp check_for_changes(state) do
    config = state.config
    repo_path = repo_path(config.name)

    if File.exists?(repo_path) do
      # Do a git fetch and compare
      case Git.sync(config.url, config.branch, repo_path) do
        {:ok, commit_sha} ->
          if commit_sha != state.last_commit do
            {:changed, commit_sha}
          else
            :unchanged
          end

        {:error, _reason} ->
          :unchanged
      end
    else
      :unchanged
    end
  end

  defp update_crd_status(state, phase, message) do
    config = state.config

    if config[:namespace] do
      status = K8s.build_status(phase, state.last_commit, state.last_sync, message)

      case K8s.update_status(config.name, config.namespace, status) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to update CRD status: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp repo_path(repo_name) do
    # Sanitize repo name for filesystem
    safe_name = String.replace(repo_name, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.join(@repo_base_path, safe_name)
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

  # CDEvents emission helpers

  defp emit_sync_event(old_state, new_state, manifest_count, duration_ms) do
    config = new_state.config

    event_opts = %{
      commit: new_state.last_commit,
      namespace: config.target_namespace,
      manifest_count: manifest_count,
      duration_ms: duration_ms,
      source_url: config.url
    }

    event =
      if old_state.last_commit == nil do
        # First sync - service deployed
        Events.service_deployed(config.name, event_opts)
      else
        # Subsequent sync - service upgraded
        Events.service_upgraded(
          config.name,
          Map.put(event_opts, :previous_commit, old_state.last_commit)
        )
      end

    maybe_emit(event)
  end

  defp emit_failure_event(state, reason, duration_ms) do
    config = state.config

    event =
      Events.sync_failed(config.name, %{
        namespace: config.target_namespace,
        error: reason,
        commit: state.last_commit,
        duration_ms: duration_ms
      })

    maybe_emit(event)
  end

  defp maybe_emit(event) do
    # Check if emitter is running
    case Process.whereis(Nopea.Events.Emitter) do
      nil ->
        :ok

      pid ->
        Emitter.emit(pid, event)
    end
  end
end
