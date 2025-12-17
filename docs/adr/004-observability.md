# ADR-004: Observability Architecture

**Status:** Accepted
**Date:** 2024-12-16

---

## Context

NOPEA needs observability that:
1. Integrates with TAPIO/AHTI ecosystem
2. Uses same event schema patterns
3. Exports to Prometheus/Grafana
4. Supports OTEL standard attributes

---

## Decision

**Adopt TAPIO's observability patterns for consistency across Finnish Stack.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    OBSERVABILITY STACK                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   NOPEA Events                                               │
│   └── AluminiEvent (follows TapioEvent pattern)                 │
│       └── CDEvents for external systems                         │
│       └── OTEL metrics for internal ops                         │
│                                                                 │
│   Prometheus Metrics                                            │
│   └── nopea_* prefix                                         │
│   └── OTEL attribute standards (k8s.*, etc.)                   │
│                                                                 │
│   Telemetry Pipeline                                            │
│   └── :telemetry for Elixir instrumentation                     │
│   └── OpenTelemetry export (optional)                           │
│   └── Prometheus /metrics endpoint                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Event Schema (AluminiEvent)

Following TAPIO's TapioEvent pattern:

```elixir
defmodule Nopea.Event do
  @moduledoc """
  AluminiEvent - follows TapioEvent schema from TAPIO.
  """

  @type event_type ::
    :sync_started |
    :sync_completed |
    :sync_failed |
    :git_fetched |
    :git_cloned |
    :apply_started |
    :apply_completed |
    :apply_failed |
    :drift_detected |
    :drift_corrected |
    :worker_started |
    :worker_stopped |
    :webhook_received

  @type severity :: :info | :warning | :error | :critical

  @type outcome :: :success | :failure | :timeout | :unknown

  @type t :: %__MODULE__{
    id: String.t(),
    timestamp: DateTime.t(),
    type: event_type(),
    severity: severity(),
    outcome: outcome(),
    repo_name: String.t(),
    namespace: String.t(),
    cluster_id: String.t(),
    # Git context
    commit: String.t() | nil,
    branch: String.t() | nil,
    # Sync context
    resources_applied: non_neg_integer() | nil,
    duration_ms: non_neg_integer() | nil,
    # Error context
    error_type: String.t() | nil,
    error_message: String.t() | nil,
    # Trigger
    trigger: :webhook | :poll | :reconcile | :startup | :manual,
    # Custom attributes (OTEL standard names)
    attributes: map()
  }

  defstruct [
    :id,
    :timestamp,
    :type,
    :severity,
    :outcome,
    :repo_name,
    :namespace,
    :cluster_id,
    :commit,
    :branch,
    :resources_applied,
    :duration_ms,
    :error_type,
    :error_message,
    :trigger,
    attributes: %{}
  ]
end
```

### Event Type Taxonomy

| Type | Subtype | Severity | When |
|------|---------|----------|------|
| `sync_started` | - | info | Sync begins |
| `sync_completed` | - | info | Sync succeeds |
| `sync_failed` | git_error, parse_error, apply_error | error | Sync fails |
| `git_fetched` | - | info | Git fetch completes |
| `git_cloned` | - | info | Initial clone completes |
| `apply_started` | - | info | K8s apply begins |
| `apply_completed` | - | info | K8s apply succeeds |
| `apply_failed` | conflict, validation, auth | error | K8s apply fails |
| `drift_detected` | - | warning | K8s differs from git |
| `drift_corrected` | - | info | Drift fixed |
| `worker_started` | - | info | Worker process starts |
| `worker_stopped` | - | info | Worker process stops |
| `webhook_received` | github, gitlab, bitbucket | info | Webhook arrives |

---

## 2. OTEL Attribute Standards

Following TAPIO's OTEL_ATTRIBUTE_STANDARDS.md:

### Resource Attributes (set once at startup)

```elixir
# Service identification
service.name: "nopea"
service.version: "1.0.0"
service.instance.id: "nopea-abc123"

# Kubernetes context
k8s.cluster.name: "prod-us-east"
k8s.namespace.name: "nopea-system"
k8s.pod.name: "nopea-controller-xyz"
k8s.node.name: "node-1"
```

### Event Attributes (set per event)

```elixir
# GitOps context
nopea.repo.name: "my-app"
nopea.repo.url: "https://github.com/org/my-app.git"
nopea.repo.branch: "main"
nopea.repo.commit: "abc123"
nopea.repo.path: "deploy/"

# Sync context
nopea.sync.trigger: "webhook"      # webhook, poll, reconcile, startup
nopea.sync.duration_ms: 1500
nopea.sync.resources_applied: 5

# Error context
error.type: "git_error"
error.message: "network timeout"
```

---

## 3. Prometheus Metrics

Following AHTI's metrics patterns:

### Core Metrics

```elixir
defmodule Nopea.Metrics do
  @moduledoc """
  Prometheus metrics for NOPEA.
  """

  use PromEx.Plugin

  # Sync metrics
  def sync_metrics do
    [
      # Counter: syncs by outcome
      counter(
        [:nopea, :syncs, :total],
        event: [:nopea, :sync, :stop],
        tags: [:repo_name, :trigger, :outcome],
        description: "Total syncs by repo, trigger, and outcome"
      ),

      # Histogram: sync duration
      distribution(
        [:nopea, :sync, :duration, :milliseconds],
        event: [:nopea, :sync, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:repo_name, :trigger],
        description: "Sync duration in milliseconds"
      ),

      # Counter: resources applied
      counter(
        [:nopea, :resources, :applied, :total],
        event: [:nopea, :apply, :stop],
        tags: [:repo_name, :resource_kind],
        description: "Total resources applied by kind"
      )
    ]
  end

  # Git metrics
  def git_metrics do
    [
      # Counter: git operations
      counter(
        [:nopea, :git, :operations, :total],
        event: [:nopea, :git, :stop],
        tags: [:repo_name, :operation, :outcome],
        description: "Git operations (clone, fetch) by outcome"
      ),

      # Histogram: git operation duration
      distribution(
        [:nopea, :git, :duration, :milliseconds],
        event: [:nopea, :git, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:repo_name, :operation],
        description: "Git operation duration"
      )
    ]
  end

  # Worker metrics
  def worker_metrics do
    [
      # Gauge: active workers
      last_value(
        [:nopea, :workers, :active],
        event: [:nopea, :worker, :count],
        measurement: :count,
        description: "Number of active worker processes"
      ),

      # Counter: worker restarts
      counter(
        [:nopea, :workers, :restarts, :total],
        event: [:nopea, :worker, :restart],
        tags: [:repo_name],
        description: "Worker process restarts"
      )
    ]
  end

  # Cache metrics
  def cache_metrics do
    [
      # Counter: cache hits/misses
      counter(
        [:nopea, :cache, :total],
        event: [:nopea, :cache, :access],
        tags: [:cache_name, :result],  # result: hit | miss
        description: "Cache access by result"
      )
    ]
  end

  # Error metrics
  def error_metrics do
    [
      counter(
        [:nopea, :errors, :total],
        event: [:nopea, :error],
        tags: [:repo_name, :error_type],
        description: "Errors by type"
      )
    ]
  end
end
```

### Metric Names (Prometheus format)

```prometheus
# Sync metrics
nopea_syncs_total{repo_name="my-app",trigger="webhook",outcome="success"} 42
nopea_sync_duration_milliseconds_bucket{repo_name="my-app",trigger="webhook",le="1000"} 38
nopea_resources_applied_total{repo_name="my-app",resource_kind="Deployment"} 15

# Git metrics
nopea_git_operations_total{repo_name="my-app",operation="fetch",outcome="success"} 100
nopea_git_duration_milliseconds_bucket{repo_name="my-app",operation="fetch",le="5000"} 95

# Worker metrics
nopea_workers_active 10
nopea_workers_restarts_total{repo_name="my-app"} 2

# Cache metrics
nopea_cache_total{cache_name="commits",result="hit"} 500
nopea_cache_total{cache_name="commits",result="miss"} 50

# Error metrics
nopea_errors_total{repo_name="my-app",error_type="git_timeout"} 3
```

---

## 4. Telemetry Implementation

Using Elixir's `:telemetry` library:

```elixir
defmodule Nopea.Telemetry do
  @moduledoc """
  Telemetry event emission.
  """

  # Emit sync events
  def sync_started(repo_name, trigger) do
    :telemetry.execute(
      [:nopea, :sync, :start],
      %{system_time: System.system_time()},
      %{repo_name: repo_name, trigger: trigger}
    )
  end

  def sync_completed(repo_name, trigger, duration_ms, resources_applied) do
    :telemetry.execute(
      [:nopea, :sync, :stop],
      %{duration: duration_ms},
      %{
        repo_name: repo_name,
        trigger: trigger,
        outcome: :success,
        resources_applied: resources_applied
      }
    )
  end

  def sync_failed(repo_name, trigger, duration_ms, error_type) do
    :telemetry.execute(
      [:nopea, :sync, :stop],
      %{duration: duration_ms},
      %{
        repo_name: repo_name,
        trigger: trigger,
        outcome: :failure,
        error_type: error_type
      }
    )
  end

  # Emit git events
  def git_operation(repo_name, operation, outcome, duration_ms) do
    :telemetry.execute(
      [:nopea, :git, :stop],
      %{duration: duration_ms},
      %{repo_name: repo_name, operation: operation, outcome: outcome}
    )
  end

  # Emit cache events
  def cache_access(cache_name, result) do
    :telemetry.execute(
      [:nopea, :cache, :access],
      %{},
      %{cache_name: cache_name, result: result}
    )
  end

  # Emit error events
  def error(repo_name, error_type, message) do
    :telemetry.execute(
      [:nopea, :error],
      %{},
      %{repo_name: repo_name, error_type: error_type, message: message}
    )
  end
end
```

---

## 5. SLOs (Service Level Objectives)

Following AHTI's SLO patterns:

### Sync SLOs

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| Sync latency p99 | < 30s | > 60s for 5m |
| Sync success rate | > 99% | < 95% for 5m |
| Git fetch latency p99 | < 10s | > 30s for 5m |
| Apply latency p99 | < 5s | > 10s for 5m |

### Worker SLOs

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| Worker restart rate | < 1/hour | > 3/hour |
| Worker memory | < 50MB/repo | > 100MB/repo |

### Cache SLOs

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| Cache hit rate | > 80% | < 60% for 10m |

---

## 6. Prometheus Alerts

```yaml
groups:
  - name: nopea_alerts
    rules:
      - alert: HighSyncLatency
        expr: histogram_quantile(0.99, rate(nopea_sync_duration_milliseconds_bucket[5m])) > 60000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Sync latency p99 exceeds 60s"

      - alert: LowSyncSuccessRate
        expr: >
          sum(rate(nopea_syncs_total{outcome="success"}[5m])) /
          sum(rate(nopea_syncs_total[5m])) < 0.95
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Sync success rate below 95%"

      - alert: HighWorkerRestarts
        expr: rate(nopea_workers_restarts_total[1h]) > 3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Worker restart rate exceeds 3/hour"

      - alert: LowCacheHitRate
        expr: >
          sum(rate(nopea_cache_total{result="hit"}[10m])) /
          sum(rate(nopea_cache_total[10m])) < 0.6
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Cache hit rate below 60%"
```

---

## 7. CDEvents Mapping

AluminiEvent maps to CDEvents (from ADR-003):

| AluminiEvent Type | CDEvent Type |
|-------------------|--------------|
| sync_started | dev.cdevents.deployment.started |
| sync_completed | dev.cdevents.deployment.finished |
| sync_failed | dev.cdevents.deployment.failed |
| git_fetched | dev.cdevents.repository.changed |

---

## 8. Integration with Finnish Stack

### TAPIO Integration

TAPIO can correlate NOPEA events with infrastructure events:

```
NOPEA sync_started → TAPIO correlates with:
├── Network events (git fetch traffic)
├── Container events (new pods starting)
└── K8s events (deployment rollout)
```

### AHTI Integration

AHTI stores NOPEA events for historical analysis:

```
NOPEA → CDEvents → NATS → AHTI → Query/Dashboards
```

### KULTA Integration

When `rolloutRef` is set, NOPEA triggers KULTA:

```
NOPEA sync_completed → KULTA deployment.started → progressive rollout
```

---

## Consequences

### Positive
- Consistent observability across Finnish Stack
- Standard OTEL attributes for ecosystem compatibility
- CDEvents for external integration
- Clear SLOs and alerting

### Negative
- More complexity than basic logging
- Dependency on Prometheus/telemetry libraries

---

**Standard metrics. Standard events. Full observability.**
