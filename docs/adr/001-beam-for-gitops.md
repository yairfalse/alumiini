# ADR-001: BEAM for GitOps

**Status:** Accepted
**Date:** 2024-12-16

---

## Context

GitOps controllers manage many Git repositories concurrently. Each repository needs:
- Periodic polling or webhook handling
- Git clone/fetch operations
- YAML parsing
- Kubernetes API calls
- State tracking (last commit, retry counts)

What runtime best supports this workload?

---

## Decision

**Use Elixir/BEAM as the runtime.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    THE KEY INSIGHT                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   GitOps = Many independent concurrent tasks                    │
│   BEAM = Built for many independent concurrent processes        │
│                                                                 │
│   One GenServer per repository.                                 │
│   Process isolation by design.                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Elixir/BEAM (chosen)** | Process isolation, ETS, supervision | Less common in K8s ecosystem |
| **Go** | K8s ecosystem standard | Need external Redis, manual queues |
| **Rust** | Performance | Async runtime complexity |

---

## Why BEAM

### 1. Process Isolation

Each repository gets its own GenServer process:

```elixir
# repo-a crashes → only repo-a affected
# repo-b, repo-c continue normally
```

Other runtimes share memory between "tasks". A panic or memory corruption affects everything.

### 2. Supervision Trees

```elixir
defmodule Nopea.Supervisor do
  use DynamicSupervisor

  # Automatic restart on failure
  # No manual retry logic needed
end
```

The runtime handles restarts. We don't implement retry loops.

### 3. ETS for Caching

```elixir
# In-process, in-memory cache
:ets.new(:commits, [:set, :public, :named_table])
:ets.insert(:commits, {"repo-a", "abc123", timestamp})
```

No Redis. No external dependencies. Cache survives process crashes (if stored in separate process).

### 4. No External Dependencies

| Feature | Other GitOps | NOPEA |
|---------|-------------|----------|
| Caching | Redis | ETS |
| Queues | External queue | GenServer mailbox |
| Rate limiting | Custom code | Process mailbox |
| Retry logic | Manual | Supervisor |

---

## Consequences

### Positive
- Crash isolation by default
- No Redis/database dependency
- Natural concurrency model
- Hot code reload possible

### Negative
- Less common in K8s ecosystem
- Team needs Elixir knowledge
- Fewer existing K8s libraries (compared to Go)

---

## Implementation Notes

### Process per Repository

```elixir
# When GitRepository created
DynamicSupervisor.start_child(Nopea.Supervisor, {Worker, git_repo})

# When GitRepository deleted
DynamicSupervisor.terminate_child(Nopea.Supervisor, pid)
```

### Message-Based Sync Triggers

```elixir
# Worker handles all sync triggers as messages
def handle_info(:poll, state), do: ...
def handle_info({:webhook, commit}, state), do: ...
def handle_call(:sync_now, _from, state), do: ...
```

### State Recovery

On restart, Worker recovers state from:
1. Kubernetes (GitRepository status)
2. Git (current HEAD)
3. ETS cache (if process crashed, not pod)

---

**BEAM is designed for exactly this workload. Use the platform.**
