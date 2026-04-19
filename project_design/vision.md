# cmux — Projects — Vision

**Status:** Draft · 2026-04-19
**Scope:** All phases (A–D) of the Project concept.
**Companion:** `project_design/phase-a-spec.md` for Phase A implementation detail.
**Source design:** `project_design/Spec.html`, `project_design/01..03-final-design-*.jpg`.

## Goal

Introduce a **Project** layer above cmux's existing workspace concept so users can juggle multiple repos at once without losing the clean sidebar they have today. Each project is 1:1 with a repo; workspaces live inside projects (typically one-per-worktree/branch); panes live inside workspaces (one-per-agent/shell).

The single most important rule: **the tab bar represents projects, the sidebar represents workspaces of the active project, panes represent agents within the active workspace.** One layer, one job.

## Mental model

Three nested concepts:

1. **Project** — top-level unit, 1:1 with a repo. User-assigned name, monogram, color. Represented as a browser-style tab at the top of the window.
2. **Workspace** — a working context inside a project (typically a git branch/worktree or an ad-hoc directory). Listed in the sidebar of the active project. A project has 0..N workspaces.
3. **Pane** — a running agent, shell, or browser inside a workspace. Split-grid inside the main content area; each pane has its own tab strip.

Pane is what cmux already has. Workspace is what cmux calls a workspace today (minus top-level status — it's now a child of a project). Project is new.

## Locked decisions

| # | Decision | Phase |
|---|---|---|
| 1 | **Thin migration**: legacy `SessionTabManagerSnapshot` workspaces wrap into a single "Default Project" per legacy window. Users can rename/split manually. No data loss. | A |
| 2 | **Global project registry** at `~/Library/Application Support/cmux/projects.json` — stores `{id, name, monogram, color, repoPath, bookmarkData, lastOpenedAt}`. Per-window persistence stores ordered list of open project ids + the active id. | A |
| 3 | Same repo open in two windows = **blocked, focus existing**. Enforced via a shared `repoPath → (windowId, projectId)` map in `AppDelegate`, keyed on canonical path. Exception: drag-out is Phase D and transfers ownership rather than duplicating. | A |
| 4 | Project identity = `uuid` (stable) + `repoPath` (canonical). Future upgrade path to git-remote / first-commit fingerprint if duplicate-clone complaints arise. | A / future |
| 5 | Workspace default under a project = same-directory workspace. Phase A **recognizes** worktrees (shows branch/diff in repo row) but does **not** create/delete them. Worktree orchestration = Phase B. | A vs B |
| 6 | **Shortcut strategy (flipped post-review):** `Cmd+T` = new project (takes precedence over today's new-pane-tab). Today's `newSurface` moves to `Cmd+Shift+T`. `Cmd+W` becomes context-cascading: close pane tab → (if last) pane → (if last) workspace → (if last) project. `Cmd+Shift+W` = close workspace (unchanged). `Cmd+Ctrl+W` = close project directly. `Ctrl+Tab` / `Ctrl+Shift+Tab` = cycle projects. `Cmd+1..9` = workspace within active project (unchanged). `Cmd+B` = toggle sidebar (takes precedence over today's toggle-file-explorer, which moves to `Cmd+Alt+B`). | A |
| 7 | Repo identity robustness: macOS security-scoped bookmark persisted alongside `repoPath`. Normalization rule: `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath()` applied at every ingress (picker, socket, relocate, bookmark resolution). Duplicates = byte-equal canonical strings. | A |
| 8 | **Ghost project tab** when repo unavailable on launch: desaturated tab, sidebar "Repo unavailable — Relocate… / Forget project" card, workspaces listed but **read-only scrollback only** (no new input/commands until relocated). | A |
| 9 | Empty project (zero workspaces) is a first-class state. Requires moving ownership above `Workspace` — new per-window `ProjectContainer` owns `[Workspace]`; `TabManager` becomes the workspace manager for the selected project. | A |
| 10 | Pane process restart on relaunch: Phase A preserves today's behavior (fresh processes, no resurrection). Pane-process persistence = future phase. | A vs future |
| 11 | Project visual identity: 8×8 color square with a **monogram** (1 grapheme cluster, user-editable, default = first grapheme of project name uppercased). Minimum 4.5:1 monogram-vs-swatch contrast in both themes. | A |
| 12 | Default project color: stable hash of canonical `repoPath` → spec palette key. User override persists until reset. | A |
| 13 | **Minimal rollup on project tab in Phase A**: single generic dot when any workspace in the project has any unseen actionable signal (`needs-input` or `error`). No counts, no color priority. Full priority-based rollup + aggregated chips = Phase B. | A vs B |
| 14 | `serviceConfig` absent from Phase A data model. Services = Phase C. | C |
| 15 | Duplicate-directory workspaces in one project = allowed. Matches today's `TabManager.addWorkspace` behavior. | A |
| 16 | Import wizard (W1): first-launch and post-close-all-projects empty state shows "Add project…" button → `NSOpenPanel` → creates one project + one starter workspace per confirmation. Smart auto-scan of `~/projects` etc. = future polish. | A |

## Phase plan

### Phase A — Foundation (this round)

**Goal:** three-layer model shipped end-to-end. Users can have projects, switch between them via tabs or shortcuts, see repo info, and persist the whole structure across relaunches.

**In:**
- `Project` data model + global registry
- Per-window `ProjectContainer` + open-project-ids persistence
- Migration from legacy `AppSessionSnapshot`
- Top-of-window project tab strip with monograms + colors
- Sidebar repo row
- Shortcut remap per Decision 6
- Import wizard (`NSOpenPanel`-based)
- Ghost-tab state for missing repos (with read-only scrollback)
- Minimal "any-signal" dot on project tab
- `project.*` v2 socket API + CLI; `workspace.*` gains optional `projectId`
- Context-cascading `Cmd+W`
- Cross-window duplicate-open block (focus existing)

**Out (explicit non-goals for Phase A):**
- Services footer, services runtime
- Drag-out project tab to new window (and the ownership transfer it implies)
- Priority-based project-tab rollup with chip counts
- Active-workspace row inline pane expansion
- `⌘K` command palette
- Pane process resurrection on relaunch
- Worktree create/delete/rename orchestration
- Cross-clone project identity (git-remote fingerprint)
- Smart home-dir auto-scan in the wizard
- Color-picker UI beyond a basic swatch grid

### Phase B — Signals & worktrees

**Goal:** complete the notification rollup story and own the worktree lifecycle.

**In:**
- Priority-based rollup on project tab (red > yellow > blue > green > orange > gray), matching Spec.html §6
- Aggregated pip chips with counts on workspace rows
- Active workspace row expands inline to show per-pane signal lines
- Pulse decay (8s) and bell auto-clear (5s) per spec
- Worktree orchestration: "new workspace" offers to create a worktree for a branch; worktree cleanup on workspace delete (with dirty-tree confirmation)
- External git activity reconciliation (watch for `git worktree prune` / branch deletion and update rows)

**Out:**
- Services, drag-out, palette, pane resurrection

### Phase C — Services

**Goal:** give each project a footer for long-running local services (postgres, api server, scrapers).

**In:**
- `Service` data model (command, cwd, env, restart policy, log capture) added to `Project`
- Services footer in sidebar (per spec §5.2)
- Process supervisor (lifecycle, health, logs) with hooks into the notification store
- Start/stop/restart actions, CLI parity
- Service status dots (green/red per spec §6)

**Out:**
- Drag-out, palette, pane resurrection

### Phase D — Power & polish

**Goal:** match the full spec feel.

**In:**
- Drag-out project tab to spawn new window; drag-back to merge (ownership transfer — unblock the cross-window duplicate case via transfer, not duplication)
- `⌘K` command palette (fuzzy: projects, workspaces, panes, commands)
- Optional pane process resurrection on relaunch (feature-flagged; `Disconnected-view` style from spec)
- Overflow chevron menu when project tabs overflow the strip
- Color/monogram customization surface
- Accessibility audit + remaining gaps

**Out:**
- Cross-window shared project state beyond the registry (each window still owns its open-project ordering; drag-out transfers ownership rather than forking)

## Data model evolution across phases

```
Phase A:
  Project { id, name, monogram, color, repoPath, bookmarkData, lastOpenedAt }
  Workspace gains: parentProjectId

Phase B:
  Project gains: worktreePolicy (optional)
  Workspace gains: worktreeBranch (optional, display-first, orchestrated when present)

Phase C:
  Project gains: services: [Service]
  Service { id, name, kind, command, env, cwd, autostart, status }

Phase D:
  No data-model changes required; drag-out is an AppDelegate ownership move.
```

## Persistence evolution

```
~/Library/Application Support/cmux/
├── projects.json                  (Phase A: global registry)
└── session-<bundleId>.json        (existing; evolves per phase)
      AppSessionSnapshot
      └── windows: [SessionWindowSnapshot]
          ├── openProjectIds: [UUID]             (Phase A; order + active)
          ├── activeProjectId: UUID?
          └── projectContainers: [SessionProjectContainerSnapshot]
              │   (one per open project id in this window; per-window workspace state)
              └── tabManager: SessionTabManagerSnapshot
                  └── workspaces: [SessionWorkspaceSnapshot]   (existing)
```

Legacy snapshots (pre-Phase-A) migrate on first launch: each `SessionWindowSnapshot.tabManager` becomes one "Default Project" in that window with a generated id and color, and its `workspaces` become that project's workspaces. Default project's `repoPath` is the most common canonical parent of its workspaces' current directories, else the first workspace's directory.

## Cross-cutting concerns

**Canonical path normalization** (used everywhere):
```swift
func canonicalRepoPath(_ raw: String) throws -> String {
    URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
}
```

**Duplicate-open guard** (`AppDelegate`):
```swift
// Keyed by canonical repoPath, valid only while a window has it open.
var repoToWindow: [String: (windowId: ObjectIdentifier, projectId: UUID)]
```

**Shortcut conflict policy** — every new cmux-owned shortcut must be:
1. An `Action` case in `KeyboardShortcutSettings.swift`
2. Exposed in Settings UI
3. Supported in `~/.config/cmux/settings.json`
4. Documented in the keyboard-shortcut and configuration docs
5. Localized via `Resources/Localizable.xcstrings`

## Accessibility

- Project identification never color-only. Monogram is the primary identifier; color is secondary.
- Monogram contrast ≥ 4.5:1 vs swatch fill in both light and dark themes.
- All new controls (tabs, wizard buttons, ghost-tab actions) expose accessibility identifiers for UI tests and VoiceOver labels.
- State (active, inactive, ghost, has-signal) encoded with shape/border/icon, not color alone.

## Open questions (deferred to later phases, tracked here)

- When worktrees are orchestrated in Phase B: dirty-tree policy on workspace delete (confirm / stash / forbid).
- Phase C service supervisor: reuse Ghostty's PTY infra or separate `Process`-based?
- Phase D drag-out: does dragging the last project tab close the source window or keep it empty?
- Future identity upgrade: opt-in re-fingerprint-my-projects one-time migration, or transparent on next create?

## Behaviors preserved across all phases

Every phase wraps existing cmux without replacing it. The concrete inventory of behaviors that must not regress — session restore, multi-window, sidebar drag/drop, notifications, browser panels, terminal latency paths, Finder services, CLI/socket API, updater, settings, localization — lives in `phase-a-spec.md §12a`. Later phases add to the wrapper; they do not rewrite what's wrapped. If a phase would alter any §12a behavior, that phase's spec must call out the change explicitly, not absorb it silently.

## Out of scope for the whole plan

- Cloud-sync of project registry (local-only).
- Cross-device state sync.
- Remote services (only local process supervisor in Phase C).
- Multi-user / team collaboration features.
- Plugin system for project types.

---

*Review loop:* after this vision is approved, `phase-a-spec.md` drops to implementation-level detail (Swift types, persistence schemas with exact JSON, CLI command signatures with error codes, acceptance tests). Subsequent phases get their own spec when we start them.
