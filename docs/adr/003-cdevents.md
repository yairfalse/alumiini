# ADR-003: CDEvents for Observability

**Status:** Accepted
**Date:** 2024-12-16

---

## Context

NOPEA needs to emit events for:
1. Logging and debugging
2. Integration with KULTA (progressive delivery)
3. Integration with SYKLI (CI/CD)
4. External dashboards and alerting

What event format should we use?

---

## Decision

**Adopt CDEvents as the event schema. Emit CloudEvents envelope.**

```
┌──────────────────────────────────────────────────────────────────┐
│                    EVENT FLOW                                     │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   NOPEA                                                       │
│   └── Sync triggers                                              │
│       └── Emit CDEvents                                          │
│           ├── Logger (human-readable)                            │
│           ├── HTTP sink (external systems)                       │
│           └── KULTA (progressive delivery trigger)               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Why CDEvents

[CDEvents](https://cdevents.dev/) is a CNCF specification for CI/CD events:

- Standard vocabulary for CI/CD
- Interoperability with Tekton, Keptn, etc.
- Bridges to OpenTelemetry traces
- Used by SYKLI (same stack)

---

## Event Mapping

### Core Events

| NOPEA Action | CDEvent Type |
|-----------------|--------------|
| Sync started | `dev.cdevents.deployment.started` |
| Sync succeeded | `dev.cdevents.deployment.finished` |
| Sync failed | `dev.cdevents.deployment.failed` |
| Git fetched | `dev.cdevents.repository.changed` |

### Custom Extensions

| NOPEA Action | Event Type |
|-----------------|------------|
| Drift detected | `dev.nopea.drift.detected` |
| Drift corrected | `dev.nopea.drift.corrected` |
| Worker started | `dev.nopea.worker.started` |
| Worker stopped | `dev.nopea.worker.stopped` |

---

## Event Schema

### deployment.started

```json
{
  "specversion": "1.0",
  "type": "dev.cdevents.deployment.started",
  "source": "nopea/default/my-app",
  "id": "dep-001",
  "time": "2024-12-16T10:30:00Z",
  "data": {
    "subject": {
      "id": "my-app",
      "type": "deployment",
      "content": {
        "artifactId": "abc123",
        "environment": "production"
      }
    },
    "customData": {
      "repoUrl": "https://github.com/org/my-app.git",
      "branch": "main",
      "commit": "abc123",
      "trigger": "webhook"
    }
  }
}
```

### deployment.finished

```json
{
  "specversion": "1.0",
  "type": "dev.cdevents.deployment.finished",
  "source": "nopea/default/my-app",
  "id": "dep-002",
  "time": "2024-12-16T10:30:05Z",
  "data": {
    "subject": {
      "id": "my-app",
      "type": "deployment",
      "content": {
        "artifactId": "abc123",
        "outcome": "success"
      }
    },
    "customData": {
      "resourcesApplied": 5,
      "duration_ms": 5000
    }
  }
}
```

---

## Implementation

```elixir
defmodule Nopea.Events do
  @moduledoc "CDEvents emission"

  def deployment_started(repo, commit, trigger) do
    %{
      specversion: "1.0",
      type: "dev.cdevents.deployment.started",
      source: source(repo),
      id: generate_id("dep"),
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        subject: %{
          id: repo.name,
          type: "deployment",
          content: %{artifactId: commit}
        },
        customData: %{
          repoUrl: repo.url,
          branch: repo.branch,
          commit: commit,
          trigger: trigger
        }
      }
    }
  end

  def deployment_finished(repo, commit, resources_count, duration_ms) do
    %{
      specversion: "1.0",
      type: "dev.cdevents.deployment.finished",
      source: source(repo),
      id: generate_id("dep"),
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        subject: %{
          id: repo.name,
          type: "deployment",
          content: %{artifactId: commit, outcome: "success"}
        },
        customData: %{
          resourcesApplied: resources_count,
          duration_ms: duration_ms
        }
      }
    }
  end

  defp source(repo) do
    "nopea/#{repo.namespace}/#{repo.name}"
  end
end
```

---

## Integration with KULTA

When `rolloutRef` is set, NOPEA sends deployment events to KULTA:

```
NOPEA ──deployment.started──► KULTA
KULTA ──starts canary──► K8s
KULTA ──deployment.progressed──► (observability)
KULTA ──deployment.finished──► NOPEA
```

KULTA subscribes to NOPEA's `deployment.started` to trigger progressive rollouts.

---

## Integration with SYKLI

CI/CD pipeline flow:

```
SYKLI ──pipelinerun.finished──► (git push)
Git ──webhook──► NOPEA
NOPEA ──deployment.started──► (observability)
```

Full traceability from code commit to production deployment.

---

## Consequences

### Positive
- Standard format, interoperable
- Full observability chain (SYKLI → NOPEA → KULTA)
- Easy integration with external systems

### Negative
- Slightly more verbose than custom events
- Dependency on CDEvents spec

---

**Standard events. Universal integration. Full observability.**
