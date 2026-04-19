# cmux — Projects — Phase A Spec

**Status:** Draft · 2026-04-19
**Scope:** Phase A only. Subsequent phases get their own specs.
**Reads:** `project_design/vision.md` (all phases), `project_design/Spec.html` (visual/design authority).
**Targets:** `Sources/Workspace.swift`, `Sources/TabManager.swift`, `Sources/SessionPersistence.swift`, `Sources/KeyboardShortcutSettings.swift`, `Sources/TerminalController.swift`, `Sources/AppDelegate.swift`, new files under `Sources/Projects/`.

## 1 · Summary

Phase A introduces a three-layer model (Project → Workspace → Pane) end-to-end without services, drag-out, priority-rollups, or worktree orchestration. The foundation:

- New `Project` data type + global JSON registry at `~/Library/Application Support/cmux/projects.json`.
- Per-window `ProjectContainer` that owns `[Workspace]`; `TabManager` becomes the workspace manager for the selected project.
- Thin migration from legacy session snapshots (one Default Project per legacy window).
- Top-of-window project tab strip; sidebar gains a repo row.
- Shortcut remap (see §6).
- Import wizard on first-launch + empty-state.
- Ghost-tab state for missing repos; read-only scrollback preserved.
- Minimal "any-signal" dot on project tabs.
- `project.*` v2 socket namespace; `workspace.*` gains optional `projectId`.

## 2 · Data model

```swift
// New file: Sources/Projects/Project.swift

@MainActor
struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String                // trimmed, 1..80 UTF-16 code units
    var monogram: String            // exactly 1 grapheme cluster
    var color: ProjectColor
    var repoPath: String            // canonical (see §7)
    var bookmarkData: Data?         // macOS security-scoped bookmark; may be nil
    var lastOpenedAt: Date
}

enum ProjectColor: Codable, Equatable {
    case palette(PaletteKey)        // preferred: references Spec palette
    case customHex(String)          // "#RRGGBB" fallback
}

enum PaletteKey: String, Codable, CaseIterable {
    case green, yellow, red, orange, purple, cyan, accent
}
```

```swift
// Sources/Workspace.swift (existing) gains:
extension Workspace {
    var parentProjectId: UUID { get set }  // non-optional; every workspace belongs to exactly one project
}
```

```swift
// New: Sources/Projects/ProjectContainer.swift
// One per open project in a window. Wraps the workspace manager for that project's
// workspaces. Multiple containers in one window share nothing except the window itself.

@MainActor
final class ProjectContainer: ObservableObject {
    let projectId: UUID
    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceId: UUID?
    var workspaceManager: TabManager        // refactored: no longer sole per-window owner
}
```

```swift
// Replaces today's per-window TabManager singleton role.
// New file: Sources/Projects/WindowProjectManager.swift

@MainActor
final class WindowProjectManager: ObservableObject {
    @Published var openProjectIds: [UUID]           // ordered; projects visible in this window's tab strip
    @Published var activeProjectId: UUID?
    @Published var containers: [UUID: ProjectContainer]   // keyed by projectId
}
```

**Invariants:**
- Every window has exactly one `WindowProjectManager`.
- `openProjectIds` order == visible tab strip order.
- `activeProjectId ∈ openProjectIds` when `openProjectIds` is non-empty.
- Each `ProjectContainer.workspaces` may be empty (first-class empty project).
- Each `Workspace.parentProjectId` matches its container's `projectId` at load time; orphans are dropped at load (see §8 migration).
- A project may be open in at most one window at a time. Cross-window duplicate open is blocked (see §7).

## 3 · Persistence

### 3.1 · Global registry

`~/Library/Application Support/cmux/projects.json`:

```json
{
  "version": 1,
  "projects": [
    {
      "id": "B2E1...",
      "name": "cmux-ex",
      "monogram": "C",
      "color": { "kind": "palette", "key": "green" },
      "repoPath": "/Users/steve/projects/cmux-ex",
      "bookmarkData": "base64…",
      "lastOpenedAt": "2026-04-19T17:12:03Z"
    }
  ]
}
```

Writes: atomic via `FileManager.replaceItemAt` through a temp file. Never partial-write to the real path.

Reads: version mismatch → the app does NOT wipe the global registry; it refuses to load and logs an error. The registry is small and hand-editable; silent wipe is the wrong default here.

### 3.2 · Per-window snapshot evolution

`AppSessionSnapshot` (`Sources/SessionPersistence.swift`) schema bumps from `v2` → `v3`. New shape:

```swift
struct SessionWindowSnapshot: Codable {
    // Existing fields preserved: geometry, etc.
    let openProjectIds: [UUID]
    let activeProjectId: UUID?
    let projectContainers: [SessionProjectContainerSnapshot]
}

struct SessionProjectContainerSnapshot: Codable {
    let projectId: UUID
    let tabManager: SessionTabManagerSnapshot     // reuses existing type; now scoped to the project
}
```

On load:
- If `version == 3` → load as-is.
- If `version < 3` → migrate (see §8).
- If `version > 3` → return `.incompatibleFuture`, do NOT wipe, present a blocking alert offering "Quit and downgrade" (spec: version mismatch must surface, not silently swallow).

### 3.3 · Policy limits

- Max projects per window: 32 (same 100–200 px tab width constraint as spec §2).
- Max projects total in registry: 256.
- Max workspaces per project: inherits existing per-window 128 cap (`SessionPersistencePolicy`).
- Max bookmark blob size: 8 KiB.

## 4 · Canonical path rule (normative)

```swift
enum RepoPath {
    /// Throws `RepoPathError.normalizationFailed` if the path cannot be canonicalized.
    static func canonical(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .normalizationFailed }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath()
        return url.path
    }
}
```

Applied at: wizard confirmation, `project.create`/`import`/`relocate` socket calls, bookmark resolution result reconciliation, duplicate-detection lookup.

Duplicate detection = byte-equal comparison of canonical paths.

## 5 · Migration (legacy → v3)

On app launch, if `AppSessionSnapshot.version < 3`:

1. Load legacy snapshot via existing decoder (returns per-window `SessionTabManagerSnapshot`).
2. For each legacy window:
    a. Determine candidate `repoPath`:
       1. Compute canonical path for every workspace's current directory.
       2. Find their common ancestor directory that contains a `.git` directory; if found, use it.
       3. Else use the first workspace's canonical directory.
    b. Create a `Project` record (new UUID, name = repo basename or "Untitled Project", monogram = first grapheme of name uppercased, color = hashed default, bookmark = attempt to create; nil on failure).
    c. Assign all legacy workspaces to this project (`parentProjectId = newProjectId`).
    d. Register the project in the global registry (dedupe via canonical path — if a project with the same canonical `repoPath` already exists in the registry, reuse it).
    e. Window's `openProjectIds = [projectId]`, `activeProjectId = projectId`.
3. Write v3 snapshot. Delete legacy snapshot only after the v3 write succeeds (via `replaceItemAt`).

Failures:
- If migration throws, the app must NOT overwrite the legacy snapshot. Show an alert ("Could not migrate your session. Starting fresh will not delete your old data. [Start fresh] [Quit]"). On "Start fresh", move the legacy file to `session-<bundleId>.legacy-<timestamp>.json` and present the first-launch wizard.

## 6 · Keyboard shortcuts

### 6.1 · New actions (added to `Sources/KeyboardShortcutSettings.swift`)

```swift
case newProject           // default ⌘T
case closeProject         // default ⌘⌃W
case nextProject          // default ⌃↹        (Ctrl+Tab)
case prevProject          // default ⌃⇧↹      (Ctrl+Shift+Tab)
case selectProjectByNumber  // default ⌃⌘1..9  (Ctrl+Cmd+1..9, switch project by index)
```

### 6.2 · Changed defaults

| Action | Today | Phase A default | Rationale |
|---|---|---|---|
| `newSurface` (new pane tab) | `⌘T` | `⌘⇧T` | `⌘T` promoted to new-project to match visual tab hierarchy |
| `toggleFileExplorer` | `⌘⌥B` | `⌘⌥B` (unchanged) | `⌘B` now reserved for `toggleSidebar` (see below) |
| new: `toggleSidebar` | — | `⌘B` | Matches spec; distinct from file explorer |

### 6.3 · Unchanged

`selectWorkspaceByNumber` (`⌘1..9`), `closeTab` (`⌘W`, now context-cascading — see §6.4), `closeWorkspace` (`⌘⇧W`), `splitRight` (`⌘D`), `splitDown` (`⌘⇧D`), `openBrowser` (`⌘⇧L`), all browser bindings, all focus-move bindings.

### 6.4 · Context-cascading `⌘W`

When invoked, resolve target in order:
1. If the focused pane has >1 pane-tab: close the active pane-tab.
2. Else if the active workspace has >1 pane: close the active pane.
3. Else if the active project has >1 workspace: close the active workspace (via existing close-workspace-with-confirmation path).
4. Else if the window has >1 open project: close the active project tab.
5. Else: close the window (existing last-thing-in-window semantics).

Each step still emits the existing close-confirmation dialogs that the current close-tab / close-workspace flow uses.

### 6.5 · Compatibility gate

Every new/changed default must:
- Be an `Action` enum case in `KeyboardShortcutSettings.swift`.
- Appear in Settings UI.
- Be overridable in `~/.config/cmux/settings.json`.
- Localized in `Resources/Localizable.xcstrings`.
- Documented in `docs/keyboard-shortcuts.md` (or equivalent).

## 7 · Socket / CLI API

### 7.1 · New `project.*` namespace (v2)

```
project.list
  → { projects: [Project], activeProjectId?: UUID, openProjectIds: [UUID], windowId: UUID }

project.create(repoPath: String, name?: String, color?: PaletteKey, windowId?: UUID)
  → Project
  errors: repo_duplicate_open, invalid_repo_path, not_a_git_repo, bookmark_failed (warning only; still creates), permission_denied

project.import(repoPath: String, windowId?: UUID)
  // alias for create but preferred terminology from wizard
  → Project

project.select(projectId: UUID, windowId?: UUID)
  → { activeProjectId: UUID }
  errors: project_not_found, project_not_open_in_window, window_not_found

project.current(windowId?: UUID)
  → { activeProject?: Project, repoAvailable: Bool }
  errors: window_not_found, no_active_project

project.close(projectId: UUID, windowId?: UUID)
  → { windowId: UUID, closed: Bool }
  errors: project_not_open_in_window, project_not_found, window_not_found

project.rename(projectId: UUID, name: String)
  → Project
  errors: project_not_found, invalid_name

project.recolor(projectId: UUID, color: PaletteKey | CustomHex)
  → Project
  errors: project_not_found, invalid_color

project.set_monogram(projectId: UUID, monogram: String)
  → Project
  errors: project_not_found, invalid_monogram

project.next(windowId?: UUID)         → { activeProjectId: UUID }
project.previous(windowId?: UUID)     → { activeProjectId: UUID }
project.select_by_index(index: Int, windowId?: UUID) → { activeProjectId: UUID }
  errors (all three): window_not_found, no_projects_open, index_out_of_bounds

project.relocate(projectId: UUID, newRepoPath: String)
  → Project
  errors: project_not_found, invalid_repo_path, not_a_git_repo, repo_duplicate_open

project.forget(projectId: UUID)
  // Removes from registry + closes from any window that has it open.
  → { forgotten: true }
  errors: project_not_found

system.identify gains `active_project_id` and `open_project_ids`.
```

### 7.2 · `workspace.*` updates

Every `workspace.*` method gains optional `projectId`. Resolution:
- If `projectId` present: route the call within that project.
- If `window_id` and `projectId` both present and mismatched (project not open in window): `project_not_open_in_window`.
- If `projectId` absent: route to the active project in the resolved window.
- If no active project in the resolved window (window has 0 open projects — possible in first-launch wizard): `no_active_project`.

### 7.3 · Canonical error codes

Every `project.*` and augmented `workspace.*` call returns one of:
`project_not_found`, `project_not_open_in_window`, `repo_duplicate_open`, `repo_unavailable`, `invalid_repo_path`, `not_a_git_repo`, `invalid_name`, `invalid_color`, `invalid_monogram`, `bookmark_failed`, `window_not_found`, `no_active_project`, `no_projects_open`, `index_out_of_bounds`, `permission_denied`, `unsupported_in_phase_a`.

### 7.4 · Focus policy compliance

Per CLAUDE.md socket focus policy, only focus-intent commands mutate app focus:
- `project.select`, `project.next`, `project.previous`, `project.select_by_index` — may raise/select the target window and project.
- All other `project.*` (create/rename/recolor/close/forget/relocate) — must NOT steal app focus or raise windows. They mutate data only.

## 8 · UI additions

### 8.1 · Top project tab strip (`Sources/Projects/ProjectTabStripView.swift`)

- Height: 36 px. Traffic lights reserved on the left (standard macOS inset).
- Tab min width: 100 px. Tab max width: 200 px.
- Overflow: when the sum of tabs' widths exceeds available space:
  - All tabs clamp at 100 px before scrolling engages.
  - Then horizontal scroll. No shrink below 100 px.
  - `⌘K` button slot on the right is reserved (Phase A disabled / "Coming in Phase D" tooltip; no side effects).
- Active tab: filled with `bg1`, 2 px top border in project color, 1 px L/R borders in `line1`, no bottom border (merges into sidebar).
- Inactive tab: transparent bg, 1 px bottom border in `line1`, no top border.
- Tab anatomy: 8 × 8 px color swatch (rounded 2 px) with 1-grapheme **monogram** centered · project name (JetBrains Mono 11–12) · optional "any-signal" dot (see §8.4) · × close (visible on hover, always visible on active).
- Drag reorder within the window: supported (updates `openProjectIds`). Drag-out = Phase D; Phase A suppresses the out-of-window drop target.

### 8.2 · Sidebar repo row (`Sources/Projects/RepoRowView.swift`)

- At top of sidebar, above `WORKSPACES · N` header.
- 10 px vertical padding. Branch icon (SF Symbol `arrow.triangle.branch` or equivalent Ghostty glyph) + repo slug text in `fg2` JetBrains Mono.
- Slug = last two path components of canonical `repoPath`, e.g. `stevex/darkmatter`. Full path on hover tooltip.
- Non-interactive (no click target).

### 8.3 · Empty state / import wizard (`Sources/Projects/ImportWizardView.swift`)

- Shown when window has 0 open projects. Also shown on first launch after migration failure.
- Centered card: `cmux` mark + "Add a project to get started" subhead + primary button `Add project…` (localized string key `wizard.addProject.button`).
- Button opens `NSOpenPanel` (directories only, `canChooseFiles = false`, `allowsMultipleSelection = false`).
- On confirm: call `project.create` via internal pathway; on error show inline banner above the button.
- On cancel: no side effects.

### 8.4 · Any-signal dot

- Rendered to the right of the project tab's name, left of ×.
- 6 px diameter, `accent` color (the simplest no-priority signal for Phase A).
- Present iff **any** workspace in the project has ANY unseen actionable signal (`needs-input` OR `error`). No counts, no hover aggregation, no color priority.
- Disappears when the user selects the project (any workspace viewed clears the aggregate, same rule as workspace-level today).
- Phase B replaces this with priority-based colored pips + count chips.

### 8.5 · Ghost project tab

- Triggered when canonical `repoPath` does not exist at launch, OR bookmark resolution returns an inaccessible target.
- Tab style: desaturated swatch + name in `fg3`. The × remains enabled.
- Sidebar: repo row shows path in `fg3` with icon `exclamationmark.triangle`. Below it, a prominent card:
  - Title: "Repo unavailable"
  - Body: last known path
  - Primary action: `Relocate…` (opens `NSOpenPanel`; on confirm calls `project.relocate`; on duplicate-canonical failure shows `repo_duplicate_open` inline)
  - Secondary action: `Forget project` (confirmation dialog, then `project.forget`)
- Workspaces: still listed and selectable. **Pane content renders in read-only mode** — existing scrollback visible, input disabled, new-pane / new-command actions grayed out. Banner above the pane strip: "Project repo unavailable. Relocate to resume work."
- `project.current` returns `repoAvailable: false`.
- `project.select` on a ghost project still works and focuses it (for the relocate flow).

### 8.6 · Close confirmations

- Close pane-tab: existing dialog.
- Close pane (last tab in pane): existing dialog.
- Close workspace (last pane in workspace): existing dialog.
- Close project tab (last workspace or explicit `Cmd+Ctrl+W`): new dialog. "Close project '{name}'? Workspaces and their state will be closed in this window. The project itself will remain in the registry and can be reopened later." — with `Close project` primary / `Cancel` default.
- Close project tab with running processes: additional warning (mirrors today's running-processes pattern at workspace close).

### 8.7 · Accessibility

- Monogram text: minimum 4.5:1 contrast vs swatch fill in both themes. Auto-select white-or-black monogram color per swatch luminance; override allowed via settings.
- Project tab `accessibilityLabel` = "{name} project, {monogram}, {colorName}. {openState}. {any-signal}" where applicable.
- Ghost tab `accessibilityLabel` includes "unavailable".
- Every project tab, wizard button, ghost card action exposes accessibility identifiers.

## 9 · Acceptance criteria (verbatim, testable)

From QA review, adopted as-is:

1. `name` must be non-empty after trim, max 80 UTF-16 code units.
2. `monogram` must be exactly 1 grapheme cluster.
3. `workspaceIds` order must equal visible sidebar order.
4. Every persisted workspace must have exactly one existing `parentProjectId`; load must drop or repair orphaned workspaces deterministically (dropped + logged).
5. A project with `workspaceIds=[]` must render the repo row and empty-state card, must not auto-create a fallback workspace on restore, and closing the final workspace must leave the project tab intact.
6. Given the same canonical `repoPath`, the default `paletteKey` must be identical across launches and across windows on the same app version. User override fully replaces the hashed value until explicitly reset.
7. Creating multiple workspaces whose working directory normalizes to the same path is allowed. The sidebar must preserve insertion order and expose distinct workspace IDs. No Phase A operation may create, delete, rename, or check out a git worktree.
8. Project tabs must never render narrower than 100 px or wider than 200 px; overflow must expose an explicit overflow affordance; project names longer than available width must truncate with ellipsis.
9. The monogram must remain visible in both light and dark themes with a minimum 4.5:1 contrast ratio against the swatch fill.
10. Before create/import/relocate, normalize the candidate path per §4. Two projects are duplicates iff canonical paths match byte-for-byte. If a bookmark resolves to a different canonical path than stored `repoPath`, update both atomically (`repoPath := resolvedPath`).
11. If bookmark creation fails, project creation must still succeed with `bookmarkData=nil`, and the UI must mark the project as path-only restoration. On next launch, unresolved path-only repos go directly to ghost state instead of silently disappearing.
12. If `repoPath` is missing or bookmark resolution fails, the project tab must remain visible with `isGhost=true`; pane content is read-only; `project.current` includes `repoAvailable=false`; `project.relocate` to a valid repo clears ghost state without changing `projectId`; `Forget project` removes the project and all child workspaces from persistence after confirmation.
13. Every `project.*` method must return one stable error code from the set in §7.3.
14. `workspace.*` with omitted `projectId` must fail with `no_active_project` when the resolved window has zero open projects.
15. Phase A project tabs must display only the minimal any-signal dot specified in §8.4; must never display counts or priority-color rollup pips.
16. Phase A relaunch must never restart prior pane processes.
17. `serviceConfig` must be absent from persisted project JSON.
18. The `⌘K` button must not invoke a command palette; it must be disabled or show a "Coming soon" placeholder with no side effects.
19. Each wizard confirmation may add exactly one new project. Existing projects in the window must remain unchanged. Cancel must be side-effect free.
20. Selecting a directory that is not a readable git repo root must fail with inline error `Selected folder is not a Git repository` and create nothing.
21. Default shortcuts after Phase A: `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle projects only (no workspace side effects); `Cmd+T` creates a project; `Cmd+Shift+T` creates a pane tab (formerly `Cmd+T`); `Cmd+1..9` selects workspace within the active project; `Cmd+B` toggles sidebar; `Cmd+Alt+B` toggles file explorer (unchanged); `Cmd+W` cascades per §6.4; `Cmd+Shift+W` closes workspace; `Cmd+Ctrl+W` closes project.

## 10 · Failure & edge-case matrix

| Situation | Behavior |
|---|---|
| Wizard: directory picker cancelled | No project created. No error banner. |
| Wizard: chose a non-directory | `NSOpenPanel` config prevents this. |
| Wizard: chose a directory that is not a git repo | Inline error: "Selected folder is not a Git repository." Allow override in Phase A? No — Phase A rejects. Ad-hoc workspaces are created _within_ a project, not as a stand-alone project. |
| Wizard: chose a directory already open in another window | `repo_duplicate_open`; inline banner offers "Focus existing window". |
| Wizard: `NSOpenPanel` returns a path that normalizes to an existing project already in the registry but not open in any window | Reopen that project in the current window. |
| Bookmark creation fails at import time | Create project with `bookmarkData=nil`; mark as path-only; log. |
| Bookmark resolves on next launch but points elsewhere | Update `repoPath` to resolved path. Re-check duplicate-open map. |
| Bookmark stale + `repoPath` missing | Ghost state. |
| Bookmark requires `startAccessingSecurityScopedResource` for background git ops | Wrap git calls in scope; balance retain/release with `stopAccessing…`. |
| User has two windows, each trying to import the same repo concurrently | Second import sees the first in the duplicate map; fails with `repo_duplicate_open`. Serialize updates to the map on a main-actor queue. |
| Schema version > supported | Surface blocking alert. No wipe. |
| `projects.json` write fails (disk full, permissions) | Roll back in-memory mutation; surface error via Sentry breadcrumb + banner. |
| Close the only open project in a window | Window enters wizard empty state. |
| Close the only project tab in the only window | Existing last-window behavior (quit-on-last-window if configured, else reveal wizard). |
| `Cmd+W` on a workspace with running processes | Existing close-workspace running-process confirmation applies. |
| `Cmd+Ctrl+W` (close project) with running processes across any of its workspaces | New combined "Close project with running processes?" confirmation listing counts. |
| Drag to reorder projects | Updates `openProjectIds`; persisted on next session flush. |
| Drag outside window | Phase A: drop rejected; tab animates back. |
| Two workspaces in one project with same canonical directory | Allowed (see criterion #7). |
| Workspace's `parentProjectId` missing at load | Orphan dropped + logged; session continues. |
| Project tab label longer than 200 px | Ellipsize; full name on hover tooltip. |

## 11 · Tests

### 11.1 · Unit (Swift)

- `RepoPathTests`: canonicalization (symlink resolution, case, trailing slash, `~` expansion rejection since `NSOpenPanel` expands, `..` resolution, empty/whitespace).
- `ProjectRegistryTests`: add/remove/rename/recolor/forget, atomic writes (inject a failing writer; assert rollback), version mismatch handling.
- `MigrationTests`: legacy snapshots of shapes encountered in the wild (1 window / N workspaces, 2 windows, 0 workspaces), orphan repair, repo-root detection, ancestor detection.
- `DuplicateMapTests`: insert/remove under canonical path; symlink equivalence; two-window race.
- `AnySignalRollupTests`: any workspace signal → tab dot; clears on select; no pips.
- `ShortcutTests`: default bindings per §6; `Cmd+W` cascade under 1/2/3/4/5 depth conditions; settings.json override round-trip.

### 11.2 · Socket / CLI (`tests_v2/`, VM)

- `test_project_namespace.py`: every `project.*` happy path + every error code.
- `test_workspace_projectid.py`: `workspace.*` with / without `projectId`; cross-window; mismatch.
- `test_project_focus_policy.py`: non-focus-intent commands do not raise windows.
- `test_project_ghost_state.py`: create, hide repo, relaunch, observe ghost, relocate, observe recovery.

### 11.3 · UI (VM XCUITest)

- `ProjectTabStripUITests`: render, overflow, reorder, active visuals, monogram contrast.
- `ImportWizardUITests`: empty-state appears, add-project flow, cancel, non-git error.
- `GhostProjectUITests`: missing-repo banner, read-only scrollback, relocate, forget.
- `ShortcutRemapUITests`: `Cmd+T` creates project; `Cmd+Shift+T` creates pane tab; `Ctrl+Tab` cycles; `Cmd+W` cascade.

Per CLAUDE.md testing policy, all UI and socket tests run via CI (`gh workflow run test-e2e.yml`) or the VM — never locally with an untagged build.

### 11.4 · Regression-commit policy

For each regression test added, follow the two-commit pattern from CLAUDE.md: failing test commit (red CI) then fix commit (green CI).

## 12 · Non-goals (explicit)

- No services, service UI, or service runtime (Phase C).
- No drag-out project tab to new window (Phase D).
- No priority-based project-tab rollup with chip counts (Phase B).
- No active-workspace row inline pane expansion (Phase B).
- No `⌘K` command palette functionality (Phase D).
- No pane process resurrection (future).
- No worktree create / delete / rename / checkout orchestration (Phase B).
- No git-remote / first-commit-SHA project identity fingerprinting (future).
- No smart home-dir auto-scan on import (future polish).
- No cloud-sync of the project registry (out of vision).
- No project-level permissions / sharing (out of vision).

## 13 · Incremental rollout order (for plan)

Recommended decomposition into plan units (writing-plans will elaborate):

1. Data model + registry persistence + canonical path helper (no UI). Unit tests green.
2. `ProjectContainer` + `WindowProjectManager` refactor of `TabManager` ownership. Existing workspace/pane flows preserved behind a "one default project" invariant.
3. Migration from legacy snapshot + registry integration.
4. Project tab strip UI + repo row + ghost tab state.
5. Import wizard + empty-state routing.
6. Shortcut remap + `Cmd+W` cascade.
7. `project.*` socket API + `workspace.*` `projectId` plumbing.
8. Any-signal dot rollup.
9. Duplicate-open block + focus-existing.
10. Accessibility pass + localization strings.
11. Tests (unit, socket, UI) layered after each of the above.

Each step should leave the build green and the app usable.
