# ADR-007: Rich CRD Status and Printer Columns

**Status:** Proposed
**Date:** 2025-12-25

---

## Context

`kubectl get gitrepositories` is the first thing users run. The output must
immediately answer: **"Is my deployment working?"**

Current output:
```
NAME     URL                          BRANCH   PHASE    COMMIT    AGE
my-app   github.com/myorg/my-app      main     Synced   abc123    5m
```

This is okay but doesn't answer:
- How many resources are managed?
- Is anything drifted?
- When was last sync?
- Are there errors I should know about?

---

## Decision

**Expand CRD status and printer columns for at-a-glance understanding.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    STATUS DESIGN PRINCIPLE                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   "kubectl get gr" should answer 80% of questions.              │
│   "kubectl describe gr" should answer the rest.                 │
│                                                                 │
│   Never make users read logs for basic status.                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## New Printer Columns

### Default View

```bash
$ kubectl get gr
NAME     URL                      BRANCH  PHASE    RESOURCES  DRIFT  LAST SYNC  AGE
my-app   github.com/org/my-app    main    Synced   12/12      0      2m         1h
api      github.com/org/api       main    Synced   8/8        2      5m         2h
web      github.com/org/web       main    Failed   -          -      10m        3h
```

| Column | Source | Meaning |
|--------|--------|---------|
| RESOURCES | `status.resourceCount/status.appliedCount` | "12/12" = all applied |
| DRIFT | `status.driftedCount` | Number of drifted resources |
| LAST SYNC | `status.lastSyncTime` | Human-readable age |

### Wide View

```bash
$ kubectl get gr -o wide
NAME     URL                      BRANCH  PHASE    RESOURCES  DRIFT  COMMIT   MESSAGE                    LAST SYNC
my-app   github.com/org/my-app    main    Synced   12/12      0      abc123   feat: add new endpoint     2m
api      github.com/org/api       main    Synced   8/8        2      def456   fix: timeout config        5m
web      github.com/org/web       main    Failed   -          -      ghi789   Error: invalid YAML        10m
```

| Column | Source | Meaning |
|--------|--------|---------|
| COMMIT | `status.lastAppliedCommit` | Short SHA |
| MESSAGE | `status.lastCommitMessage` or `status.errorMessage` | Commit message or error |

---

## Enhanced Status Fields

```yaml
status:
  # Existing
  phase: Synced | Syncing | Failed | Initializing
  lastAppliedCommit: "abc123def456"
  lastSyncTime: "2025-12-25T10:42:01Z"
  observedGeneration: 3

  # New: Resource tracking
  resourceCount: 12        # Total resources in repo
  appliedCount: 12         # Successfully applied
  driftedCount: 0          # Currently drifted
  suspendedCount: 0        # With suspend-heal annotation

  # New: Commit info
  lastCommitMessage: "feat: add new endpoint"
  lastCommitAuthor: "yair@example.com"
  lastCommitTime: "2025-12-25T10:40:00Z"

  # New: Error detail
  errorMessage: ""         # Last error (cleared on success)
  errorResource: ""        # Which resource failed

  # New: Timing
  lastSyncDuration: "2.3s" # How long sync took
  nextSyncTime: "2025-12-25T10:47:01Z"  # When next poll

  # Existing: Conditions
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2025-12-25T10:42:01Z"
      reason: SyncSucceeded
      message: "Applied 12 resources"
    - type: Drifted
      status: "False"
      lastTransitionTime: "2025-12-25T10:42:01Z"
      reason: NoDrift
      message: ""
```

---

## Conditions Strategy

Use standard Kubernetes condition types:

| Condition | Status | Meaning |
|-----------|--------|---------|
| `Ready` | True | Sync completed successfully |
| `Ready` | False | Sync failed or in progress |
| `Drifted` | True | One or more resources have drifted |
| `Drifted` | False | All resources match desired state |
| `Suspended` | True | One or more resources have suspend-heal |
| `Stalled` | True | No progress for > 2 sync intervals |

### Condition Reasons

```
Ready=True:
  - SyncSucceeded: "Applied 12 resources (1 updated)"
  - NoChanges: "Already at commit abc123"

Ready=False:
  - Syncing: "Fetching from origin/main"
  - SyncFailed: "Failed to apply Deployment/api: image not found"
  - GitFetchFailed: "Authentication failed for git repo"

Drifted=True:
  - ManualDrift: "2 resources modified outside git"
  - ConflictDrift: "Both git and cluster changed"

Stalled=True:
  - GitUnreachable: "Failed to fetch for 3 attempts"
  - K8sAPIError: "API server not responding"
```

---

## CRD Spec Update

```yaml
additionalPrinterColumns:
  - name: URL
    type: string
    jsonPath: .spec.url
  - name: Branch
    type: string
    jsonPath: .spec.branch
  - name: Phase
    type: string
    jsonPath: .status.phase
  - name: Resources
    type: string
    jsonPath: .status.resourceCount
    description: "Total resources managed"
  - name: Drift
    type: integer
    jsonPath: .status.driftedCount
    description: "Resources with drift"
  - name: Last Sync
    type: date
    jsonPath: .status.lastSyncTime
  - name: Age
    type: date
    jsonPath: .metadata.creationTimestamp
  # Wide columns (priority: 1)
  - name: Commit
    type: string
    jsonPath: .status.lastAppliedCommit
    priority: 1
  - name: Message
    type: string
    jsonPath: .status.lastCommitMessage
    priority: 1
```

---

## Implementation

### Phase 1: Add Status Fields

Update `Nopea.Worker` to track:
- Resource counts during sync
- Commit message from git head
- Sync duration timing

### Phase 2: Update CRD

Add new printer columns and status subresource fields.

### Phase 3: Condition Management

Implement standard condition handling:
- Transition timestamps
- Reason codes
- Human-readable messages

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Rich status (chosen)** | kubectl-native, no extra tools | More status fields to maintain |
| **Separate Status CRD** | Clean separation | Extra resource to query |
| **Annotations only** | Simple | Not visible in kubectl get |

---

## Success Criteria

1. `kubectl get gr` shows drift count without describe
2. `kubectl get gr -o wide` shows last error message
3. Conditions follow Kubernetes conventions (Ready, etc.)
4. Status updates within 5 seconds of state change