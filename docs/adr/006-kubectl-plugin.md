# ADR-006: kubectl-nopea Plugin

**Status:** Proposed
**Date:** 2025-12-25

---

## Context

GitOps adoption fails when the developer experience is worse than `kubectl apply`.
ArgoCD compensates with a web UI. Flux has `flux` CLI but it's verbose.

NOPEA's DX thesis: **The terminal is where developers live.** A kubectl plugin
that makes GitOps feel as immediate as raw kubectl will win adoption.

Current state:
- `kubectl get gr` shows status (good)
- Debugging drift requires reading logs (bad)
- Triggering sync requires webhook or waiting (bad)
- Break-glass requires knowing annotation syntax (friction)

---

## Decision

**Build `kubectl-nopea` plugin in Go for native kubectl integration.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    DESIGN PHILOSOPHY                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Every command should be:                                       │
│   1. Faster than opening a browser                               │
│   2. More informative than kubectl get                          │
│   3. Self-documenting via --help                                 │
│                                                                 │
│   If it takes more than 5 seconds, we failed.                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Command Reference

### `kubectl nopea status [REPO]`

Show repository status with resource-level detail.

```bash
$ kubectl nopea status my-app
Repository: my-app
URL:        https://github.com/myorg/my-app
Branch:     main
Commit:     abc123 (authored 2 minutes ago)
Phase:      Synced
Last Sync:  2025-12-25T10:42:01Z (3 minutes ago)

Resources (12 total, 1 drifted):
  ✓ Deployment/api           in sync
  ✓ Service/api              in sync
  ⚠ ConfigMap/api-config     drifted (suspend-heal: true)
  ✓ Ingress/api              in sync
  ... (8 more)
```

### `kubectl nopea diff [REPO] [RESOURCE]`

Show what differs between desired and live state.

```bash
$ kubectl nopea diff my-app
ConfigMap/default/api-config:
  data.LOG_LEVEL: "info" → "debug"  (manual change in cluster)
  data.TIMEOUT:   "30"  → "60"      (manual change in cluster)

$ kubectl nopea diff my-app ConfigMap/api-config
--- desired (git)
+++ live (cluster)
@@ -4,5 +4,5 @@
   data:
-    LOG_LEVEL: "info"
-    TIMEOUT: "30"
+    LOG_LEVEL: "debug"
+    TIMEOUT: "60"
```

### `kubectl nopea sync [REPO]`

Trigger immediate sync with live output.

```bash
$ kubectl nopea sync my-app
Triggering sync for my-app...
  → Fetching from origin/main...
  → Commit: abc123 "feat: add new endpoint"
  → Applying 12 resources...
  → Deployment/api: unchanged
  → ConfigMap/api-config: updated
  → Service/api: unchanged
  ✓ Sync completed in 2.3s (1 changed, 11 unchanged)
```

### `kubectl nopea suspend [REPO/RESOURCE]`

Add break-glass annotation.

```bash
$ kubectl nopea suspend my-app/Deployment/api
Added nopea.io/suspend-heal=true to Deployment/api in namespace default

$ kubectl nopea suspend my-app  # suspend all resources
Added nopea.io/suspend-heal=true to 12 resources
```

### `kubectl nopea resume [REPO/RESOURCE]`

Remove break-glass annotation.

```bash
$ kubectl nopea resume my-app/Deployment/api
Removed nopea.io/suspend-heal from Deployment/api

$ kubectl nopea resume my-app --sync  # resume and sync
Removed nopea.io/suspend-heal from 3 resources
Triggering sync...
```

### `kubectl nopea logs [REPO]`

Stream controller logs filtered to specific repo.

```bash
$ kubectl nopea logs my-app
2025-12-25T10:42:01Z INFO  Sync started repo=my-app commit=abc123
2025-12-25T10:42:02Z INFO  Applied resource repo=my-app kind=Deployment name=api
2025-12-25T10:42:03Z INFO  Sync completed repo=my-app duration=2.3s
```

### `kubectl nopea events [REPO]`

Show Kubernetes events for the repository.

```bash
$ kubectl nopea events my-app
LAST SEEN   TYPE      REASON          MESSAGE
3m          Normal    SyncStarted     Starting sync from abc123
3m          Normal    SyncCompleted   Applied 12 resources (1 updated)
1m          Warning   DriftDetected   ConfigMap/api-config has manual changes
```

---

## Implementation

### Language: Go

- Native kubectl plugin discovery (`kubectl-nopea` binary in PATH)
- Use `client-go` for Kubernetes access
- Use `cobra` for CLI framework
- Use `lipgloss`/`termenv` for colored output

### Package Structure

```
cmd/kubectl-nopea/
├── main.go
├── cmd/
│   ├── root.go
│   ├── status.go
│   ├── diff.go
│   ├── sync.go
│   ├── suspend.go
│   ├── resume.go
│   ├── logs.go
│   └── events.go
├── pkg/
│   ├── client/         # K8s client wrapper
│   ├── output/         # Formatters (table, json, yaml)
│   └── diff/           # YAML diff logic
└── go.mod
```

### Output Formats

All commands support `--output` flag:

```bash
kubectl nopea status my-app -o json   # JSON for scripting
kubectl nopea status my-app -o yaml   # YAML
kubectl nopea status my-app -o wide   # Extra columns
```

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Go kubectl plugin (chosen)** | Native integration, ecosystem standard | Separate binary |
| **Elixir escript** | Same language as controller | No kubectl integration |
| **Shell wrapper** | Simple | Limited functionality |

---

## Success Criteria

1. Install via `kubectl krew install nopea`
2. `kubectl nopea status` faster than ArgoCD UI load time
3. Zero configuration needed (uses kubeconfig)
4. 100% feature parity with common ArgoCD UI actions
5. Works offline (cached repo state in CRD status)

---

## References

- [kubectl plugins](https://kubernetes.io/docs/tasks/extend-kubectl/kubectl-plugins/)
- [Krew plugin manager](https://krew.sigs.k8s.io/)
- [cobra CLI framework](https://github.com/spf13/cobra)
