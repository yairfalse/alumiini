defmodule Nopea.Metrics do
  @moduledoc """
  Telemetry metrics for NOPEA GitOps controller.

  Exposes Prometheus-compatible metrics for:
  - Sync operations (duration, success/failure)
  - Git operations (clone, fetch)
  - Worker counts
  - Drift detection and healing
  - Leader election status

  ## Usage

  Metrics are emitted using the `emit_*` functions. These emit telemetry
  events that are then scraped by Prometheus via the `/metrics` endpoint.

  ## Metric Names

  All metrics are prefixed with `nopea_`:

  - `nopea_sync_duration_seconds` - Histogram of sync durations
  - `nopea_sync_total` - Counter of sync operations by status
  - `nopea_workers_active` - Gauge of active workers
  - `nopea_git_clone_duration_seconds` - Histogram of git clone durations
  - `nopea_git_fetch_duration_seconds` - Histogram of git fetch durations
  - `nopea_drift_detected_total` - Counter of drift detections
  - `nopea_drift_healed_total` - Counter of drift healings
  - `nopea_leader_status` - Gauge of leader status (1=leader, 0=standby)
  """

  import Telemetry.Metrics

  @doc """
  Returns list of telemetry metric definitions for Prometheus.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Sync metrics
      distribution("nopea.sync.duration",
        unit: {:native, :second},
        description: "Sync operation duration",
        tags: [:repo],
        reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60]]
      ),
      counter("nopea.sync.total",
        event_name: [:nopea, :sync, :stop],
        description: "Total sync operations",
        tags: [:repo, :status]
      ),
      counter("nopea.sync.error.total",
        event_name: [:nopea, :sync, :error],
        description: "Total sync errors",
        tags: [:repo, :error]
      ),

      # Worker metrics
      last_value("nopea.workers.active",
        description: "Number of active workers",
        measurement: :count
      ),

      # Git operation metrics
      distribution("nopea.git.clone.duration",
        unit: {:native, :second},
        description: "Git clone duration",
        tags: [:repo],
        reporter_options: [buckets: [0.5, 1, 2, 5, 10, 30, 60, 120]]
      ),
      distribution("nopea.git.fetch.duration",
        unit: {:native, :second},
        description: "Git fetch duration",
        tags: [:repo],
        reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 30]]
      ),

      # Drift metrics
      counter("nopea.drift.detected",
        description: "Drift detection events",
        tags: [:repo, :resource],
        measurement: :count
      ),
      counter("nopea.drift.healed",
        description: "Drift healing events",
        tags: [:repo, :resource],
        measurement: :count
      ),

      # Leader election metrics
      last_value("nopea.leader.status",
        description: "Leader status (1=leader, 0=standby)",
        tags: [:pod],
        measurement: :status
      ),
      counter("nopea.leader.transitions.total",
        event_name: [:nopea, :leader, :change],
        description: "Leader transitions",
        tags: [:pod]
      )
    ]
  end

  @doc """
  Emit telemetry event when sync starts.
  Returns the start time for calculating duration.
  """
  @spec emit_sync_start(map()) :: integer()
  def emit_sync_start(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nopea, :sync, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc """
  Emit telemetry event when sync completes successfully.
  """
  @spec emit_sync_stop(integer(), map()) :: :ok
  def emit_sync_stop(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nopea, :sync, :stop],
      %{duration: duration},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event when sync fails.
  """
  @spec emit_sync_error(integer(), map()) :: :ok
  def emit_sync_error(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nopea, :sync, :error],
      %{duration: duration},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event for git operations (clone, fetch).
  """
  @spec emit_git_operation(:clone | :fetch, integer(), map()) :: :ok
  def emit_git_operation(operation, duration, metadata) do
    :telemetry.execute(
      [:nopea, :git, operation, :stop],
      %{duration: duration},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event when drift is detected.
  """
  @spec emit_drift_detected(map()) :: :ok
  def emit_drift_detected(metadata) do
    :telemetry.execute(
      [:nopea, :drift, :detected],
      %{count: 1},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event when drift is healed.
  """
  @spec emit_drift_healed(map()) :: :ok
  def emit_drift_healed(metadata) do
    :telemetry.execute(
      [:nopea, :drift, :healed],
      %{count: 1},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event for leader status changes.
  """
  @spec emit_leader_change(map()) :: :ok
  def emit_leader_change(%{is_leader: is_leader} = metadata) do
    status = if is_leader, do: 1, else: 0

    :telemetry.execute(
      [:nopea, :leader, :change],
      %{status: status},
      metadata
    )

    :ok
  end

  @doc """
  Emit telemetry event for active worker count.
  """
  @spec set_active_workers(non_neg_integer()) :: :ok
  def set_active_workers(count) do
    :telemetry.execute(
      [:nopea, :workers, :active],
      %{count: count},
      %{}
    )

    :ok
  end
end
