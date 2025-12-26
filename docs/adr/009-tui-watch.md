# ADR-009: TUI Watch Mode

**Status:** Proposed
**Date:** 2025-12-25

---

## Context

ArgoCD's killer feature is its real-time UI showing sync status and resource health.
But the UI requires:
- Browser window
- Port forwarding or ingress
- Authentication setup

For developers who live in the terminal, a **Terminal UI (TUI)** provides the same
real-time visibility without leaving the command line.

---

## Decision

**Build `kubectl nopea watch` as a real-time TUI dashboard.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    TUI DESIGN GOALS                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. Real-time updates (WebSocket/watch API)                    │
│   2. Keyboard navigation (vim-style)                            │
│   3. Resource drill-down                                         │
│   4. Action shortcuts (sync, suspend, resume)                   │
│   5. Works over SSH (no graphics required)                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Interface Design

### Main Dashboard

```
┌─ NOPEA ─────────────────────────────────── 10:42:01 ─ Watching ─┐
│                                                                  │
│  Repositories (3)                                 [?] help       │
│  ──────────────────────────────────────────────────────────────  │
│  ✓ my-app     main   abc123   Synced    12 resources    2m ago  │
│  ⚠ api        main   def456   Drifted   8 resources     5m ago  │
│  ✗ frontend   main   ghi789   Failed    -               10m ago │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Recent Events                                                   │
│  ──────────────────────────────────────────────────────────────  │
│  10:42:01  my-app     SyncCompleted   Applied 12 resources      │
│  10:41:58  my-app     SyncStarted     Fetching abc123           │
│  10:40:15  api        DriftDetected   ConfigMap/settings        │
│  10:35:22  frontend   SyncFailed      Invalid YAML line 42      │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│ [s]ync  [d]iff  [p]ause  [r]esume  [l]ogs  [↵]details  [q]uit  │
└──────────────────────────────────────────────────────────────────┘
```

### Repository Detail View

```
┌─ my-app ────────────────────────────────── 10:42:01 ─ Synced ───┐
│                                                                  │
│  Repository: https://github.com/myorg/my-app.git                │
│  Branch:     main                                                │
│  Path:       deploy/                                             │
│  Commit:     abc123 - "feat: add new endpoint" (2 minutes ago)  │
│                                                                  │
│  Resources (12)                                                  │
│  ──────────────────────────────────────────────────────────────  │
│  ✓ Deployment/api              apps/v1     default    in sync   │
│  ✓ Service/api                 v1          default    in sync   │
│  ⚠ ConfigMap/api-config        v1          default    drifted   │
│  ✓ Ingress/api                 netv1       default    in sync   │
│  ✓ ServiceAccount/api          v1          default    in sync   │
│  ... (7 more - scroll with j/k)                                  │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│ [s]ync  [d]iff  [p]ause  [r]esume  [←]back  [↵]resource  [q]uit │
└──────────────────────────────────────────────────────────────────┘
```

### Resource Detail View

```
┌─ ConfigMap/api-config ──────────────────── 10:42:01 ─ Drifted ──┐
│                                                                  │
│  Status: Manual drift detected                                   │
│  Suspend-heal: false                                             │
│  Last applied: 2025-12-25T10:30:00Z                             │
│                                                                  │
│  Drift Details                                                   │
│  ──────────────────────────────────────────────────────────────  │
│  --- desired (git)                                               │
│  +++ live (cluster)                                              │
│  @@ -4,5 +4,5 @@                                                 │
│     data:                                                        │
│  -    LOG_LEVEL: "info"                                         │
│  +    LOG_LEVEL: "debug"                                        │
│  -    TIMEOUT: "30"                                             │
│  +    TIMEOUT: "60"                                             │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│ [s]ync resource  [p]ause healing  [y]ank diff  [←]back  [q]uit  │
└──────────────────────────────────────────────────────────────────┘
```

### Sync Progress View

```
┌─ Syncing my-app ─────────────────────────────────────────────────┐
│                                                                  │
│  Commit: abc123 - "feat: add new endpoint"                      │
│  Author: yair@example.com                                        │
│                                                                  │
│  Progress                                                        │
│  ──────────────────────────────────────────────────────────────  │
│  ████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░  8/12 (67%)  │
│                                                                  │
│  ✓ Deployment/api           applied (unchanged)                  │
│  ✓ Service/api              applied (unchanged)                  │
│  ✓ ConfigMap/api-config     applied (updated)                   │
│  ✓ Ingress/api              applied (unchanged)                  │
│  ✓ ServiceAccount/api       applied (unchanged)                  │
│  ✓ Role/api                 applied (unchanged)                  │
│  ✓ RoleBinding/api          applied (unchanged)                  │
│  → Secret/api-tls           applying...                          │
│  ○ HPA/api                  pending                              │
│  ○ PDB/api                  pending                              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Keyboard Shortcuts

### Global

| Key | Action |
|-----|--------|
| `q` | Quit |
| `?` | Show help |
| `r` | Refresh |
| `/` | Search/filter |
| `Esc` | Cancel/back |

### Navigation

| Key | Action |
|-----|--------|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `Enter` | Select/drill down |
| `Backspace` / `←` | Go back |
| `g` | Go to top |
| `G` | Go to bottom |

### Actions

| Key | Action |
|-----|--------|
| `s` | Sync selected |
| `S` | Sync all |
| `d` | Show diff |
| `p` | Pause/suspend healing |
| `P` | Resume healing |
| `l` | View logs |
| `e` | View events |
| `y` | Yank (copy) to clipboard |

---

## Implementation

### Technology: Go + Bubble Tea

Use [Bubble Tea](https://github.com/charmbracelet/bubbletea) framework:
- Elm-architecture for TUI
- [Lip Gloss](https://github.com/charmbracelet/lipgloss) for styling
- [Bubbles](https://github.com/charmbracelet/bubbles) for components

```go
package main

import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/charmbracelet/lipgloss"
)

type model struct {
    repos      []Repository
    cursor     int
    view       View  // dashboard | detail | resource | sync
    watching   bool
    lastUpdate time.Time
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyMsg:
        switch msg.String() {
        case "q":
            return m, tea.Quit
        case "j", "down":
            m.cursor++
        case "s":
            return m, syncRepo(m.repos[m.cursor])
        }
    case RepoUpdateMsg:
        m.repos = msg.Repos
    }
    return m, nil
}
```

### Real-time Updates

Use Kubernetes watch API:

```go
func watchRepositories(ctx context.Context) tea.Cmd {
    return func() tea.Msg {
        watcher, _ := client.Watch(ctx, &gitRepoList)
        for event := range watcher.ResultChan() {
            return RepoUpdateMsg{Event: event}
        }
        return nil
    }
}
```

### Package Structure

```
cmd/kubectl-nopea/
├── tui/
│   ├── app.go           # Main application
│   ├── model.go         # State management
│   ├── views/
│   │   ├── dashboard.go # Main dashboard
│   │   ├── detail.go    # Repo detail
│   │   ├── resource.go  # Resource detail
│   │   ├── sync.go      # Sync progress
│   │   └── help.go      # Help overlay
│   ├── components/
│   │   ├── table.go     # Repo table
│   │   ├── events.go    # Events list
│   │   ├── diff.go      # Diff viewer
│   │   └── progress.go  # Progress bar
│   └── styles/
│       └── styles.go    # Lip Gloss styles
```

---

## Color Scheme

```go
var (
    successStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))  // green
    warningStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("214")) // orange
    errorStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("196")) // red
    mutedStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("242")) // gray
    headerStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("99"))
)
```

Respects `NO_COLOR` environment variable for accessibility.

---

## Alternatives Considered

| Option | Pros | Cons |
|--------|------|------|
| **Bubble Tea (chosen)** | Beautiful, active community | Go only |
| **Ratatui (Rust)** | Very fast | Different language from plugin |
| **tview (Go)** | Simple | Less pretty |
| **Plain watch output** | Zero dependencies | Not interactive |

---

## Success Criteria

1. Starts in < 500ms
2. Updates within 1 second of cluster changes
3. Works over SSH without issues
4. Accessible (respects NO_COLOR, screen readers)
5. All actions available via keyboard (no mouse required)
6. Handles 100+ repositories without lag

---

## Demo Script (CDCon)

```bash
# Start watching
$ kubectl nopea watch

# [Navigate to a repo with j/k]
# [Press Enter to see details]
# [Press d to see diff]
# [Press s to sync]
# [Watch the progress bar fill]
# [Press q to quit]

# Total demo time: 60 seconds
# Lines of YAML shown: 0
# Browsers opened: 0
```