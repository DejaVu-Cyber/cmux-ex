# cmux Projects — Phase A Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:decompose-to-tickets to create Linear tickets from this plan, then choose local (subagent-driven-development) or Symphony execution. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Project layer above Workspace per `project_design/phase-a-spec.md` — data model, persistence v3, tab strip, repo row, ghost-tab state, shortcut remap, socket API, import wizard — in an order that leaves the build green and the app usable after every step.

**Architecture:** A new per-window `WindowProjectManager` owns an ordered set of `ProjectContainer`s; each container wraps today's `TabManager` (demoted to "workspace manager for the selected project"). Project identity is persisted globally in `~/Library/Application Support/cmux/projects.json`; per-window snapshots store ordered project IDs + per-project container state. Existing terminal/browser/pane/notification code is wrapped, not rewritten.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, macOS 13+, existing Ghostty/Bonsplit/cmuxd infra. Persistence = Codable JSON. Tests split across XCTest unit, `tests_v2/` Python socket, VM XCUITest.

**Source documents:**
- `project_design/vision.md` (all phases)
- `project_design/phase-a-spec.md` (this plan implements §1–§13)
- `project_design/Spec.html` (visual authority)
- `CLAUDE.md` (shortcut / localization / testing / socket-focus / socket-threading policies)

---

## File structure

### New files

```
Sources/Projects/
  Project.swift                     // Project struct + ProjectColor + PaletteKey
  ProjectRegistry.swift             // Global projects.json read/write
  ProjectContainer.swift            // @MainActor container for one project in one window
  WindowProjectManager.swift        // @MainActor per-window root; replaces TabManager's root role
  ProjectMigration.swift            // v2 → v3 thin migration
  RepoPath.swift                    // canonical path helper
  ProjectDuplicateRegistry.swift    // cross-window repoPath → (windowId, projectId)
  ProjectTabStripView.swift         // top-of-window tab strip
  ProjectTabView.swift              // single tab with monogram + name + any-signal dot + close
  RepoRowView.swift                 // sidebar repo row
  GhostProjectCardView.swift        // "Repo unavailable — Relocate/Forget" sidebar card
  ImportWizardView.swift            // first-launch / empty-state entry
  ProjectColorHash.swift            // stable-hash(canonicalPath) → PaletteKey
  ProjectMonogramView.swift         // monogram glyph rendering with contrast pick
  AnySignalRollup.swift             // Phase A minimal rollup (any unseen actionable → dot)

Sources/Projects/SocketAPI/
  ProjectSocketCommands.swift       // project.* command dispatch
  ProjectErrorCode.swift            // canonical error enum (16 codes per §7.3)

cmuxTests/
  RepoPathTests.swift
  ProjectRegistryTests.swift
  ProjectMigrationTests.swift
  ProjectDuplicateRegistryTests.swift
  AnySignalRollupTests.swift
  ShortcutCascadeTests.swift
  ProjectColorHashTests.swift

tests_v2/
  test_project_namespace.py
  test_workspace_projectid.py
  test_project_focus_policy.py
  test_project_ghost_state.py

cmuxUITests/
  ProjectTabStripUITests.swift
  ImportWizardUITests.swift
  GhostProjectUITests.swift
  ShortcutRemapUITests.swift
```

### Modified files

```
Sources/Workspace.swift                     // +parentProjectId
Sources/TabManager.swift                    // demoted to per-project; removes root ownership
Sources/SessionPersistence.swift            // +v3 shape, +migration entrypoint, +projects.json path
Sources/AppDelegate.swift                   // WindowProjectManager wiring, MainWindowContext update,
                                            //   duplicate-open map, first-launch → wizard routing
Sources/TerminalController.swift            // +project.* dispatch; +optional projectId on workspace.*
Sources/KeyboardShortcutSettings.swift      // +newProject/closeProject/nextProject/prevProject/selectProjectByNumber;
                                            //   default remap for newSurface (Cmd+T → Cmd+Shift+T)
Sources/cmuxApp.swift                       // menu wiring for new shortcut actions + Debug menu entry
Sources/ContentView.swift                   // embed ProjectTabStripView above existing sidebar/content
Resources/Info.plist                        // no new UTTypes for Phase A (reorder-within-strip uses existing pattern)
Resources/Localizable.xcstrings             // en/ja entries for all new strings
CLI/cmux.swift                              // add `project-*` subcommands mirroring socket API
docs/keyboard-shortcuts.md (or equivalent)  // document shortcut changes
```

---

## Tasks

### Task 1: Canonical path helper + Project + PaletteKey data model

**Files:**
- Create: `Sources/Projects/RepoPath.swift`
- Create: `Sources/Projects/Project.swift`
- Test: `cmuxTests/RepoPathTests.swift`

**What to build:** Pure types for the Phase A data model and the one canonical-path rule used everywhere.

**Interface:**
```swift
enum RepoPathError: Error { case empty, normalizationFailed }

enum RepoPath {
    /// Canonical form used at EVERY ingress: picker, socket, relocate, bookmark reconcile.
    /// Applies trim → URL(fileURLWithPath:) → standardizedFileURL → resolvingSymlinksInPath.
    static func canonical(_ raw: String) throws -> String
}

struct Project: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String          // 1..80 UTF-16 code units after trim
    var monogram: String      // exactly one grapheme cluster
    var color: ProjectColor
    var repoPath: String      // canonical
    var bookmarkData: Data?
    var lastOpenedAt: Date
}

enum ProjectColor: Codable, Equatable, Hashable {
    case palette(PaletteKey)
    case customHex(String)    // "#RRGGBB"
}

enum PaletteKey: String, Codable, CaseIterable { case green, yellow, red, orange, purple, cyan, accent }
```

**Behavior to test (RepoPath):**
- Empty / whitespace input throws `.empty`.
- Relative path → absolute (`../foo` resolves against cwd).
- Trailing slash normalized.
- Symlink chain resolves to target path.
- Case preserved (APFS is case-insensitive but case-preserving; canonical string uses real case).

**Behavior to test (Project):**
- Round-trip JSON encoding produces byte-identical bytes given the same value.
- `name` and `monogram` validators enforced via a non-throwing factory or explicit `validate()` — pick one; document in the file.

**Constraints:**
- No dependencies on `TabManager`, `Workspace`, or any AppKit type.
- `ProjectColor` hex must be `#` + 6 hex digits, uppercased on normalize.
- Do NOT add `isGhost` as a persisted field (derived at runtime — see spec §8.5).

**Depends on:** none.

---

### Task 2: Global project registry (projects.json)

**Files:**
- Create: `Sources/Projects/ProjectRegistry.swift`
- Modify: `Sources/SessionPersistence.swift` (add `projectsRegistryFileURL` helper, reuse atomic-write machinery)
- Test: `cmuxTests/ProjectRegistryTests.swift`

**What to build:** An actor-isolated registry that loads / saves `projects.json` atomically, with version gating.

**Interface:**
```swift
@MainActor
final class ProjectRegistry: ObservableObject {
    @Published private(set) var projects: [UUID: Project]

    static let currentVersion: Int = 1

    static func shared() -> ProjectRegistry          // lazy singleton; lives for app lifetime
    func load() throws                                // reads projects.json; throws on v > current
    func save() throws                                // atomic replaceItemAt through temp file
    func upsert(_ project: Project)                   // in-memory only; save() to persist
    func remove(_ id: UUID)
    func byCanonicalPath(_ path: String) -> Project?  // helper for dedupe
}
```

**Behavior to test:**
- Save + reload produces value-equal registry.
- Version > `currentVersion` throws; registry remains unloaded (no wipe).
- Partial-write failure (inject failing writer) leaves existing file untouched; throws.
- Missing file → empty registry, no throw.
- Corrupt JSON throws a specific error; existing file preserved.
- `byCanonicalPath` matches byte-equal canonical paths only.

**Constraints:**
- Use `FileManager.replaceItemAt` via a temp file in the same directory; never write directly to `projects.json`.
- Max 256 projects total (§3.3); reject `upsert` beyond that with a specific error.
- Bookmark blob limit 8 KiB enforced at upsert.
- File path = `~/Library/Application Support/cmux/projects.json`, shared across tagged builds only if bundle ID matches (follow existing session-file-per-bundle-ID pattern).

**Depends on:** Task 1.

---

### Task 3: Duplicate-open registry (in-memory)

**Files:**
- Create: `Sources/Projects/ProjectDuplicateRegistry.swift`
- Test: `cmuxTests/ProjectDuplicateRegistryTests.swift`

**What to build:** Small `@MainActor` map used by `AppDelegate` to enforce the "same repo in two windows = blocked, focus existing" rule.

**Interface:**
```swift
@MainActor
final class ProjectDuplicateRegistry {
    struct Location { let windowId: ObjectIdentifier; let projectId: UUID }

    /// Returns nil if this repoPath is not open anywhere; else returns where.
    /// Must be called after RepoPath.canonical normalization.
    func location(forCanonicalPath: String) -> Location?

    /// Register a project as open in a window. Returns .conflict(Location) if
    /// already registered under the same canonical path elsewhere.
    func open(canonicalPath: String, location: Location) -> OpenResult

    /// Unregister when a project's tab closes in that window.
    func close(canonicalPath: String, windowId: ObjectIdentifier)

    enum OpenResult { case opened, conflict(Location) }
}
```

**Behavior to test:**
- Open then close clears entry.
- Second open of same canonical path from a different window returns `.conflict` with the first window's `Location`.
- Two different canonical paths from same window both succeed.
- Closing a window id that isn't registered is a no-op.

**Constraints:**
- `Location.windowId` is `ObjectIdentifier`, not UUID (per spec §12b regression risk #1). Do not introduce window UUIDs here or anywhere.
- `@MainActor` isolation — all access from the main actor. No lock types.

**Depends on:** Task 1.

---

### Task 4: ProjectContainer + WindowProjectManager (shells only, no persistence yet)

**Files:**
- Create: `Sources/Projects/ProjectContainer.swift`
- Create: `Sources/Projects/WindowProjectManager.swift`
- Test: (unit covered via integration in later tasks; behavior is trivial here)

**What to build:** The new ownership layer, shells only — does not yet replace `TabManager` root role. Task 5 does that swap.

**Interface:**
```swift
@MainActor
final class ProjectContainer: ObservableObject, Identifiable {
    let projectId: UUID
    @Published var workspaces: [Workspace]
    @Published var selectedWorkspaceId: UUID?
    let workspaceManager: TabManager   // wraps existing TabManager; Task 5 scopes it

    init(projectId: UUID, workspaces: [Workspace], workspaceManager: TabManager)
}

@MainActor
final class WindowProjectManager: ObservableObject {
    @Published var openProjectIds: [UUID]
    @Published var activeProjectId: UUID?
    @Published var containers: [UUID: ProjectContainer]

    /// Convenience — returns the active container or nil if openProjectIds is empty (wizard state).
    var activeContainer: ProjectContainer? { get }

    func openProject(_ project: Project, inserting: InsertPolicy) throws
    func closeProject(_ projectId: UUID) throws
    func selectProject(_ projectId: UUID) throws
    func reorder(projectIds: [UUID])    // full-order replacement
}

enum InsertPolicy { case atEnd, afterActive, atStart }
```

**What to build (deferred behavior for this task):**
- `WindowProjectManager` does not yet talk to `SessionPersistence`, `ProjectRegistry`, or `ProjectDuplicateRegistry`. Task 5 wires persistence; Task 6 wires dup-registry.
- `containers` is a strong-ref dictionary. Container lifetime is tied to being in `containers`.

**Constraints:**
- `openProjectIds` order == visible tab strip order (spec invariant).
- `activeProjectId ∈ openProjectIds` when non-empty; else nil.
- Workspaces within a container preserve existing `TabManager` selection semantics (Cmd+1..9, placement preference, sidebar drag reorder).
- Do NOT introduce locking; `@MainActor` isolation suffices.

**Depends on:** Task 1.

---

### Task 5: TabManager demotion — ownership refactor

**Files:**
- Modify: `Sources/TabManager.swift` (remove per-window-root assumptions where they exist; expose container-scoped entrypoints)
- Modify: `Sources/Workspace.swift` (add non-optional `parentProjectId: UUID`)
- Modify: `Sources/AppDelegate.swift` (`MainWindowContext` gains `WindowProjectManager`; callers that reached into `TabManager` to reach "the" workspace list now go through `WindowProjectManager.activeContainer?.workspaceManager`)
- Modify: `Sources/ContentView.swift` (sidebar binds to `activeContainer`'s workspace manager)
- Modify: `Sources/SessionPersistence.swift` (snapshot types updated; migration written in Task 7, stub here)

**What to build:** Flip the ownership model. After this task, every window has a `WindowProjectManager`; `TabManager` instances live inside `ProjectContainer`s. Exactly one default project per window (name "Default Project", generated uuid) is created on window init so all existing workflows continue working. Persistence still round-trips v2 via a trivial serializer — no v3 writer yet.

**Behavior to test (integration, existing tests):**
- `cmuxTests/WorkspaceLifecycleTests.swift` (if it exists) and other TabManager unit tests still pass with zero changes beyond mechanical imports.
- Multi-window (`Cmd+Shift+N`) still creates an independent window with its own `WindowProjectManager` + one default project.
- Workspace `Cmd+1..9`, sidebar reorder, `Cmd+D`/`Cmd+Shift+D` split, file drop all still work.
- Notifications still route per-window (spec §12a).

**Constraints:**
- **Window identity stays `ObjectIdentifier`** (§12b regression risk #1).
- **UUIDs of Workspace/Panel/Pane stay globally unique within a window** (§12b regression risk #2). `ProjectContainer` must NOT rekey anything.
- `TerminalNotificationStore` stays per-window; containers share it (§12b regression risk #3).
- No user-visible change in Phase A UI after this task completes. Tab strip (Task 9), ghost tab (Task 11), etc. come later.
- Preserve TabItemView equatable optimization and the pane-latency-sensitive paths called out in CLAUDE.md / §12a.
- Any new `@Published` field you add to `ProjectContainer` must not be read from inside pane body views.
- Migrations NOT in this task — Task 7 handles legacy data.

**Depends on:** Tasks 1, 4.

---

### Task 6: Duplicate-open block wired

**Files:**
- Modify: `Sources/AppDelegate.swift` (owns a single `ProjectDuplicateRegistry`, calls `open` on window create, `close` on tab close / window close)
- Modify: `Sources/Projects/WindowProjectManager.swift` (consults registry in `openProject`; returns a well-typed error on conflict)
- Test: additions to `cmuxTests/ProjectDuplicateRegistryTests.swift` cover the wiring

**What to build:** Enforce cross-window block + focus-existing.

**Behavior to test:**
- Open project with repoPath X in window A; attempting to open the same repoPath in window B raises existing window A (non-focus-stealing scenarios described in §7.4 do not apply because this is a user-intent action).
- Reasonable race — two calls to open same repo in same tick: first wins, second returns `.conflict`.
- Close in window A clears the registry; re-open in window B now succeeds.
- Symlink to same target blocked (relies on Task 1 canonicalization).

**Constraints:**
- Only fire focus on an explicit user open path (wizard confirm, socket `project.create`/`import`, menu action). The non-focus-intent socket commands (rename, recolor, forget on an inactive project) must not raise windows (§7.4).

**Depends on:** Tasks 3, 4, 5.

---

### Task 7: Persistence schema v3 + legacy migration

**Files:**
- Modify: `Sources/SessionPersistence.swift` (v3 writer + reader; legacy-detect + migration entrypoint)
- Create: `Sources/Projects/ProjectMigration.swift` (pure migration logic, isolated for testing)
- Modify: `Sources/AppDelegate.swift` (first-launch routing: `.migrated → normal restore`, `.fresh → wizard`, `.future → alert`, `.migrationFailed → alert + legacy preserved`)
- Test: `cmuxTests/ProjectMigrationTests.swift`

**What to build:** Version-gated load. On `version == 3` load directly; on `version < 3` call `ProjectMigration.migrate(legacy:)` synchronously before window creation; on `version > 3` surface blocking alert (no wipe).

**Interface:**
```swift
enum ProjectMigration {
    struct Outcome {
        let registryAdditions: [Project]
        let snapshot: AppSessionSnapshotV3
    }
    enum Error: Swift.Error { case candidateRepoPathNotFound(windowIndex: Int), bookmarkSkipped }

    /// Deterministic given a legacy snapshot. Does not touch disk.
    static func migrate(legacy: AppSessionSnapshotV2, existing: [UUID: Project]) throws -> Outcome
}
```

**Behavior to test:**
- Legacy snapshot with 1 window / N workspaces → 1 Default Project with N workspaces.
- 2 windows → 2 Default Projects with separate UUIDs.
- Legacy snapshot with 0 workspaces in a window → empty Default Project (no fallback workspace injected).
- Candidate `repoPath` = deepest common ancestor containing `.git`; else first workspace's canonical directory.
- If `existing` already has a project with the same canonical path, migration reuses it (no duplicate Project in registry).
- Migration is total: every legacy workspace ends up under exactly one project, no orphans.
- Migration failure preserves the legacy file (rename to `session-<bundleId>.legacy-<ts>.json` is handled by `AppDelegate`, not `ProjectMigration`, but returns a sentinel so caller knows).

**Constraints:**
- `ProjectMigration` must be pure (no `FileManager`, no global singletons). Disk side effects are the caller's job.
- Bookmark creation during migration may fail; project still created with `bookmarkData=nil` (per §10 failure matrix).
- Color assignment uses `ProjectColorHash` (Task 15); for this task, use a deterministic stub and wire real hash in Task 15.

**Depends on:** Tasks 1, 2, 4, 5.

---

### Task 8: Keyboard shortcut remap + Cmd+W cascade

**Files:**
- Modify: `Sources/KeyboardShortcutSettings.swift` (new `Action` cases; changed defaults; keep existing `toggleSidebar` binding)
- Modify: `Sources/cmuxApp.swift` / menu construction (wire new actions to menu items)
- Modify: `Sources/AppDelegate.swift` (implement context-cascading `Cmd+W` per §6.4; new-project / close-project handlers)
- Test: `cmuxTests/ShortcutCascadeTests.swift`

**New actions:**
```
newProject               default ⌘T
closeProject             default ⌘⌃W
nextProject              default ⌃↹
prevProject              default ⌃⇧↹
selectProjectByNumber    default ⌃⌘1..9
```

**Changed default:**
- `newSurface`: `⌘T` → `⌘⇧T`. All existing `newSurface` call sites keep working; only the default key changes.

**Behavior to test:**
- `Cmd+W` cascade under five depth conditions (pane has >1 tab; pane is sole; workspace has >1 pane; workspace is sole; project is sole). Each escalation step emits the correct confirmation dialog.
- `Cmd+T` creates a project (opens wizard → import path).
- `Cmd+Shift+T` creates a pane tab (formerly `Cmd+T`).
- `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle projects only; no workspace side effect when only one project is open.
- `Cmd+Ctrl+W` closes active project tab (with running-process confirm if any workspace has live panes).
- `~/.config/cmux/settings.json` round-trips all new actions.
- Settings UI shows the new actions with current bindings.
- Localizable strings added for each action label.

**Constraints:**
- Follow CLAUDE.md shortcut policy: Action case + Settings UI + settings.json support + docs update + localized label.
- Do not regress existing `toggleSidebar` at `⌘B`, `toggleFileExplorer` at `⌘⌥B`, `selectWorkspaceByNumber` at `⌘1..9`, split / focus-move / browser bindings, flash focus, notification shortcuts, bell/update shortcuts.
- Cascade uses existing close dialogs (§8.6) — do NOT invent new confirmation UI for intermediate steps.

**Depends on:** Tasks 5, 7.

---

### Task 9: Project tab strip UI + tab geometry + monogram + overflow

**Files:**
- Create: `Sources/Projects/ProjectTabStripView.swift`
- Create: `Sources/Projects/ProjectTabView.swift`
- Create: `Sources/Projects/ProjectMonogramView.swift`
- Create: `Sources/Projects/ProjectColorHash.swift`
- Create: `cmuxTests/ProjectColorHashTests.swift`
- Modify: `Sources/ContentView.swift` (embed strip above existing sidebar/content; reserve traffic lights inset)
- Modify: `Resources/Localizable.xcstrings` (tab accessibility labels, "Coming soon" palette tooltip for ⌘K)
- Test: `cmuxUITests/ProjectTabStripUITests.swift`

**What to build:** The top strip (36 px), with tabs (100–200 px) carrying 8×8 color swatch + monogram + name + any-signal dot (wired in Task 13) + ×. Overflow = clamp to 100 px then horizontal scroll. `⌘K` slot visible but disabled.

**Constraints:**
- Active-tab visual: filled `bg1`, 2 px top accent in project color, 1 px L/R `line1`, no bottom (merges into sidebar below).
- Monogram contrast ≥ 4.5:1 against swatch in both themes; use luminance threshold to pick white vs black text.
- Drag-reorder **within window only** — drop outside window rejected in Phase A (tab animates back).
- Do NOT introduce new `UTType`s for Phase A (intra-strip reorder via existing pasteboard pattern).
- Stable hash: `ProjectColorHash.palette(for: canonicalPath)` deterministic across launches and windows.
- Accessibility identifiers on each tab (`project-tab-<monogram>`), wizard button, `⌘K` button.

**Behavior to test:**
- Render N tabs; visually verify geometry (via snapshot or geometry assertions).
- Overflow: width = sum > viewport → clamp then scroll, no shrink below 100 px.
- Drag reorder updates `openProjectIds`; persisted on next session flush.
- Drag outside window → snap back; no ownership move.
- `ProjectColorHash` same canonical path → same `PaletteKey` across runs.
- Monogram remains legible across all palette swatches in light + dark themes.

**Depends on:** Tasks 1, 4, 5.

---

### Task 10: Sidebar repo row + ghost project card

**Files:**
- Create: `Sources/Projects/RepoRowView.swift`
- Create: `Sources/Projects/GhostProjectCardView.swift`
- Modify: `Sources/ContentView.swift` (insert repo row above existing `WORKSPACES · N` header)
- Modify: `Resources/Localizable.xcstrings` (ghost-card strings)
- Test: `cmuxUITests/GhostProjectUITests.swift`

**What to build:**
- Repo row: branch icon + `last-two-path-components` slug in `fg2` JetBrains Mono, 10 px vertical padding, non-interactive, tooltip shows full canonical path.
- Ghost card: "Repo unavailable" title + last known path + `Relocate…` primary + `Forget project` secondary. Pane bodies in ghost state render existing scrollback in a read-only wrapper with "Project repo unavailable. Relocate to resume work." banner at the top; new input/commands disabled; splits disabled.
- `isGhost` derived at runtime from `!FileManager.fileExists(repoPath) || !bookmarkResolves()`.

**Behavior to test:**
- Normal project: repo row shows slug, no card.
- Ghost project (inject missing repoPath): card appears, workspaces listed, pane body read-only with banner, input blocked.
- `Relocate…` opens `NSOpenPanel`, on confirm with valid repo path calls `project.relocate`, ghost clears, projectId preserved.
- `Relocate…` to a path already open in another window → `repo_duplicate_open` inline error in card.
- `Forget project` → confirmation → `project.forget` → project removed from registry, all child workspaces removed, tab disappears.

**Constraints:**
- Read-only wrapper must not disturb scrollback rendering or Ghostty surface lifetime; disable input at the `hitTest` layer, not by unloading the surface.
- Banner text localized.
- Accessibility labels include "unavailable".

**Depends on:** Tasks 1, 4, 5, 9.

---

### Task 11: Import wizard + empty-state routing

**Files:**
- Create: `Sources/Projects/ImportWizardView.swift`
- Modify: `Sources/AppDelegate.swift` (first-launch routing; post-close-all-projects empty state)
- Modify: `Resources/Localizable.xcstrings` (wizard copy)
- Test: `cmuxUITests/ImportWizardUITests.swift`

**What to build:** Centered card in the main content area when window has 0 open projects. "Add a project to get started" + `Add project…` button → `NSOpenPanel` (directories only) → calls internal equivalent of `project.create`. Inline error banner on failure.

**Behavior to test:**
- Fresh install → wizard shown.
- Migration success → no wizard, projects restored.
- Closing the only open project in a window → wizard shown.
- Cancel picker → no state change, no banner.
- Pick non-git directory → inline "Selected folder is not a Git repository" banner, no project created.
- Pick repo already open in another window → inline `repo_duplicate_open` banner with "Focus existing window" action.
- Pick repo already in registry but closed → reopens in current window (no duplicate registry entry).

**Constraints:**
- Only dir selection allowed (`NSOpenPanel.canChooseFiles = false`).
- Bookmark creation attempted; failure downgrades to path-only, project still created.
- Starter workspace created with `workingDirectory = canonical repoPath`.
- New-workspace placement preference (`Top` / `After current` / `End`) does NOT apply to the starter workspace — it's always the sole workspace at index 0.
- Wizard button, picker, banner all localized + accessibility-identified.

**Depends on:** Tasks 2, 4, 5, 6, 7.

---

### Task 12: `project.*` socket API + `workspace.*` projectId plumbing

**Files:**
- Create: `Sources/Projects/SocketAPI/ProjectSocketCommands.swift`
- Create: `Sources/Projects/SocketAPI/ProjectErrorCode.swift`
- Modify: `Sources/TerminalController.swift` (dispatch `project.*`; thread optional `projectId` through existing `workspace.*` handlers)
- Modify: `CLI/cmux.swift` (new `project-*` subcommands mirroring socket methods)
- Test: `tests_v2/test_project_namespace.py`, `tests_v2/test_workspace_projectid.py`, `tests_v2/test_project_focus_policy.py`, `tests_v2/test_project_ghost_state.py`

**What to build:** All methods listed in spec §7.1–§7.3 with exactly the 16-code error set.

**Behavior to test (each command):**
- Happy path for every method.
- Every error code from §7.3 reachable via at least one test case.
- Focus policy: non-focus-intent commands (create/rename/recolor/close/forget/relocate) must not raise windows or activate the app — test by observing `NSApp.isActive` pre/post.
- Ghost project: mutating `workspace.*` → `repo_unavailable`; read-only `workspace.list/current` succeeds.
- `window_id + projectId` mismatch → `project_not_open_in_window`.
- `workspace.*` without `projectId` on a window with zero open projects → `no_active_project`.
- Omitting `projectId` falls through to active project in resolved window.

**Constraints:**
- Follow CLAUDE.md socket-threading policy: structural mutation on main; nothing blocks on main longer than necessary.
- Follow CLAUDE.md socket-focus policy: only explicit focus-intent commands mutate focus.
- Every command's error mapping goes through `ProjectErrorCode`; no stringly-typed errors escape.
- CLI subcommands maintain stable exit codes mirroring error codes (0 = success, 2 = invalid usage, 3+ = per-error-code mapping; document in `cmux.swift` header comment).

**Depends on:** Tasks 4, 5, 6, 7.

---

### Task 13: Any-signal rollup dot

**Files:**
- Create: `Sources/Projects/AnySignalRollup.swift`
- Modify: `Sources/Projects/ProjectTabView.swift` (consume rollup output; render dot)
- Modify: `Sources/TerminalNotificationStore.swift` if needed — only to expose a workspace-set-aware "any unseen actionable" query (do not fork the store)
- Test: `cmuxTests/AnySignalRollupTests.swift`

**What to build:** A reactive `Bool` per project derived from its workspaces' notification states: true iff ANY workspace has ANY unseen actionable signal (`needs-input` OR `error`).

**Interface:**
```swift
@MainActor
struct AnySignalRollup {
    /// Publisher returning Bool; subscribe per project tab.
    static func publisher(for projectId: UUID,
                          in container: ProjectContainer,
                          store: TerminalNotificationStore) -> AnyPublisher<Bool, Never>
}
```

**Behavior to test:**
- Container with zero workspaces → false.
- Container with one workspace having an unseen error → true; selecting the workspace clears → false.
- Any workspace's new unseen `needs-input` → true.
- `new-output` only (informational) → false (Phase A only rolls up actionable).
- `bell` only (ambient) → false in Phase A (we keep it out of project tab; pane dot only).

**Constraints:**
- No polling; debounce is OK (≤ 100 ms) to avoid flicker.
- Must not add work in pane-tab per-keystroke paths (spec §12a).
- Dot size = 6 px, color = `accent`. No counts, no priority chromatics — Phase B adds those.

**Depends on:** Tasks 4, 5, 9.

---

### Task 14: Finder service path-aware routing + Debug menu Project Tab Debug

**Files:**
- Modify: `Sources/AppleScriptSupport.swift` or the existing Finder service handler (route "New Workspace Here" and "New Window Here" per §12a path-aware decision)
- Create: `Sources/Projects/ProjectTabDebugWindow.swift` (debug build only; Sidebar Debug-style window for tuning tab width bounds, monogram contrast override, any-signal dot visibility)
- Modify: `Sources/cmuxApp.swift` (add Project Tab Debug to `Debug > Debug Windows` alphabetical list)

**What to build:**
- "New Workspace Here" path-aware: if resolved Finder path is inside active project's canonical `repoPath`, create workspace inside active project. Else prompt: "Create new project for {repoName}?" → yes creates project + starter workspace at that path; no cancels.
- "New Window Here": always creates new window with one project at that path (existing `openWindow` semantics + project wrapper).
- Project Tab Debug window (DEBUG only): live toggles for the tab strip so design iteration doesn't require rebuild.

**Behavior to test:**
- Finder drop inside a workspace dir of active project → workspace created, no prompt.
- Finder drop outside any active project canonical root → prompt, create-project path.
- Finder drop on a dir that matches an existing project in the registry → reopen that project + create starter workspace at the dropped path if different from repoPath.

**Constraints:**
- Localized prompt strings.
- Debug window `#if DEBUG` only; no production code paths reference it.
- Never open an untagged cmux DEV.app (CLAUDE.md).

**Depends on:** Tasks 4, 5, 7, 9.

---

### Task 15: Accessibility + localization pass

**Files:**
- Modify: `Resources/Localizable.xcstrings` (English + Japanese for every new string introduced in Tasks 9–14)
- Modify: every new SwiftUI view in `Sources/Projects/` (audit `accessibilityLabel`, `accessibilityIdentifier`, VoiceOver order)
- No new test file; coverage merges into existing `ProjectTabStripUITests`, `ImportWizardUITests`, `GhostProjectUITests`, `ShortcutRemapUITests`

**What to build:** Sweep. Every new user-facing string goes through `String(localized:)` with a stable key. Every new control has `accessibilityIdentifier`. Monogram contrast check runs in a test.

**Behavior to test:**
- Grep `Sources/Projects` for bare string literals in `Text()`, `Button()`, `.alert(...)`, tooltips — zero matches.
- Snapshot-verify monogram luminance flips white↔black at the correct boundary.
- VoiceOver announces tabs as "{name} project, {monogram}, {colorName}. {openState}. {any-signal?}".

**Constraints:**
- Every new key has an English default and a Japanese translation — do not ship a key without ja.
- Keys follow existing naming (`shortcut.nextProject.label`, `projectTab.accessibility.announce`, etc.).

**Depends on:** Tasks 8, 9, 10, 11, 12, 13, 14.

---

### Task 16: Regression spot-check suite + PROJECTS.md update

**Files:**
- Create: `cmuxUITests/ProjectRefactorRegressionTests.swift` (one-per-area spot checks against §12a)
- Modify: `PROJECTS.md` (add the Phase A completion entry)

**What to build:** A compact suite that asserts every §12a area still works post-refactor. This is a targeted regression sheet, not a full re-test of cmux — 1–2 assertions per area, hitting the highest-risk behaviors.

**Behavior to test (one per area from §12a):**
- Persistence: launch → restore a v3 snapshot with 2 projects × 2 workspaces × panes → every workspace shows in the correct project sidebar with its panes.
- Multi-window: `Cmd+Shift+N` → second window has its own `WindowProjectManager`, tab strip, sidebar, notification routing.
- Sidebar: drag reorder a workspace; context-menu Move Up works; edge auto-scroll during drag.
- Shortcuts: `Cmd+D` split, `Cmd+Alt+Arrow` focus move, `Cmd+Shift+L` flash.
- Notifications: unseen actionable in a background project → project tab any-signal dot lights; Cmd+I popover opens; Dock badge reflects total unread.
- Browser: `Cmd+L` context-aware; `Cmd+R` reload; split with `Cmd+D`.
- Pane latency: typing into a terminal does not regress (assert via existing visual-typing harness if present, else defer to CI latency probe).
- Files/drag-drop: drop file onto terminal inserts shell-escaped path.
- CLI: `cmux identify` reflects `active_project_id` and `open_project_ids`; `list-panes`, `list-pane-surfaces` unchanged.
- Updater: pill renders; `Receive nightly builds` toggle persists.
- Settings: custom shortcut round-trips via `~/.config/cmux/settings.json`.
- Debug: `Debug > Debug Windows > Project Tab Debug` opens.

**Constraints:**
- Run via CI (`gh workflow run test-e2e.yml`) per CLAUDE.md — never locally against an untagged build.
- Follow the two-commit regression-test policy (CLAUDE.md): add failing test first (red), then fix (green). For this task the "fix" is just confirming the refactor didn't regress — tests should be green in commit 2 by verifying against the just-built Phase A app.

**Depends on:** all prior tasks.

---

## Cross-cutting requirements (apply to every task)

- **Window identity remains `ObjectIdentifier`**, not UUID. Every task that touches `AppDelegate` / `MainWindowContext` re-verifies this.
- **UUIDs for Workspace / Panel / Pane remain globally unique within a window**, not container-scoped.
- **`TerminalNotificationStore` stays per-window**; `ProjectContainer` does not own a notification store.
- **Pane-typing-latency paths** (CLAUDE.md) untouched by any Projects-layer work. No `@EnvironmentObject`/`@ObservedObject` added to `TabItemView` without `==` update; `WindowTerminalHostView.hitTest()` pointer guard preserved; `TerminalSurface.forceRefresh()` no-alloc; `SurfaceSearchOverlay` stays mounted from `GhosttySurfaceScrollView`.
- **Localization**: every new string via `String(localized:)` with a key in `Resources/Localizable.xcstrings` covering en + ja. No bare literals in `Text()`, `Button()`, menus, alerts, tooltips.
- **Shortcut policy**: new cmux-owned shortcuts are `Action` cases, appear in Settings, round-trip `~/.config/cmux/settings.json`, are documented, are localized.
- **Testing policy**: never run tests locally against an untagged build. E2E/UI/socket via CI or VM with a tagged socket. Unit tests are fine locally.
- **Build policy**: every code change builds with `./scripts/reload.sh --tag phase-a-<step>` before commit; never launch an untagged `cmux DEV.app`.
- **Regression-test commit pattern**: two-commit structure for any regression test added for a bug fix (red + green).
- **Focus policy**: non-focus-intent socket commands must not steal focus.
- **Threading policy**: structural changes on main; telemetry hot paths off-main.

## Out of scope for this plan (Phase B/C/D)

- Priority-based project-tab rollup with count chips (Phase B).
- Aggregated pip chips on workspace rows (Phase B).
- Active workspace row inline pane expansion (Phase B).
- Worktree create/delete/rename/checkout orchestration (Phase B).
- External git activity reconciliation (Phase B).
- Services footer + service supervisor (Phase C).
- Drag-out project tab to new window (Phase D).
- `⌘K` command palette (Phase D).
- Pane process resurrection on relaunch (future phase).
- Cross-clone project identity fingerprint (future).
- Smart home-dir auto-scan in wizard (future polish).
- Color-picker UI beyond a basic swatch grid (future polish).
