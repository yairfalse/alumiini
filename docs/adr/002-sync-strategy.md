# ADR-002: Sync Strategy

**Status:** Accepted
**Date:** 2024-12-16

---

## Context

How should NOPEA detect and react to Git changes?

Options:
1. Webhook only (reactive)
2. Poll only (periodic)
3. Hybrid (webhook + poll)

---

## Decision

**Use hybrid: Webhook (primary) + Poll (backup) + Reconcile (drift).**

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYNC TRIGGERS                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Priority 1: WEBHOOK                                           │
│   └── Git push → HTTP POST → Worker.sync_now()                  │
│   └── Latency: ~1-2 seconds                                     │
│                                                                 │
│   Priority 2: POLL                                              │
│   └── Timer → git fetch → compare HEAD → sync if changed        │
│   └── Catches missed webhooks                                   │
│   └── Configurable interval (default: 5m)                       │
│                                                                 │
│   Priority 3: RECONCILE                                         │
│   └── Timer → compare cached hashes → K8s actual → fix drift    │
│   └── Detects manual kubectl edits                              │
│   └── Configurable interval (default: 10m)                      │
│                                                                 │
│   Priority 4: STARTUP                                           │
│   └── Process start → sync to ensure consistency                │
│   └── Handles controller restarts                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| Webhook only | Fast, efficient | Missed webhooks = missed syncs |
| Poll only | Simple, reliable | High latency, wasted API calls |
| **Hybrid (chosen)** | Fast + reliable | Slightly more complex |

---

## Implementation

### Webhook Handler

```elixir
defmodule Nopea.Webhook.Endpoint do
  use Plug.Router

  post "/webhook/github" do
    with {:ok, body, conn} <- read_body(conn),
         :ok <- verify_signature(conn, body),
         {:ok, payload} <- Jason.decode(body),
         {:ok, repo_url} <- extract_repo_url(payload),
         {:ok, commit} <- extract_commit(payload) do

      # Find matching Worker and trigger sync
      case find_worker_for_url(repo_url) do
        {:ok, pid} ->
          send(pid, {:webhook, commit})
          send_resp(conn, 200, "OK")
        {:error, :not_found} ->
          send_resp(conn, 404, "No matching GitRepository")
      end
    end
  end
end
```

### Poll Timer

```elixir
defmodule Nopea.Worker do
  def init(config) do
    # Schedule first poll
    timer = schedule_poll(config.interval)
    {:ok, %{config: config, poll_timer: timer}}
  end

  def handle_info(:poll, state) do
    case check_for_changes(state) do
      {:changed, new_commit} ->
        sync(state.config, new_commit)
      :unchanged ->
        :ok
    end

    # Schedule next poll
    timer = schedule_poll(state.config.interval)
    {:noreply, %{state | poll_timer: timer}}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
```

### Reconcile (Drift Detection)

```elixir
def handle_info(:reconcile, state) do
  # Compare what we applied vs what's in K8s
  case detect_drift(state) do
    {:drifted, resources} ->
      Logger.warn("Drift detected", resources: resources)
      reapply(resources)
    :in_sync ->
      :ok
  end

  timer = schedule_reconcile(state.config.reconcile_interval)
  {:noreply, %{state | reconcile_timer: timer}}
end
```

---

## Webhook Configuration

### GitHub

```yaml
# In GitHub repo settings
Webhook URL: https://nopea.example.com/webhook/github
Content type: application/json
Secret: <shared-secret>
Events: Push events
```

### GitLab

```yaml
Webhook URL: https://nopea.example.com/webhook/gitlab
Secret Token: <shared-secret>
Trigger: Push events
```

---

## Failure Handling

### Webhook Failures

If webhook POST fails:
1. GitHub retries automatically (up to 3 times)
2. Poll catches it within `interval`
3. No manual intervention needed

### Poll Failures

If poll fails (network, git error):
1. Worker retries with exponential backoff
2. Supervisor restarts if process crashes
3. Next poll continues normally

### Reconcile Failures

If reconcile detects drift but can't fix:
1. Update GitRepository status to `Drifted`
2. Emit CDEvent `deployment.failed`
3. Continue polling for source changes

---

## Consequences

### Positive
- Sub-second sync on push (webhook)
- Reliable sync even without webhooks (poll)
- Drift detection prevents configuration drift
- Self-healing on restart (startup sync)

### Negative
- Need to configure webhooks per repo (optional)
- Polling uses some API quota
- Reconcile adds K8s API load

---

**Webhook for speed. Poll for reliability. Reconcile for correctness.**
