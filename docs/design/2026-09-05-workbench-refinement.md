# IexCode workbench refinement

The workspace should give tasks, code, and execution records most of the window.
Its navigation and controls should explain where the user is and what can happen
next without competing with that work.

## Direction

- One grouped workspace sidebar; the header shows the current view and a compact
  view switcher instead of duplicating every destination as an icon strip.
- A quiet neutral canvas, restrained accent, and native macOS typography.
  Monospace is reserved for identifiers, code, and operational data.
- Rounded rectangles define controls and panels. Pills indicate status, rather
  than enclosing every action and navigation group.
- Compact task toolbar with task creation beside filters. Empty collapsed stages
  should not resemble full-height empty columns.
- A compact idle composer that expands for writing and run setup.
- One Settings category navigation with contextual section links, concise
  preference groups, and a save footer that never covers fields.
- Mission Control leads with useful state and the run ledger. Long explanatory
  headings and repeated metrics yield to execution details.

All five themes, independent shadow and effect preferences, reduced motion,
sidebar resizing, model selection, workflow events, and persistent drafts remain.
Native macOS Quit and Cmd+N fixes ship with the same package.

## Validation

- The initial integrated precommit covered 178 tests. Three legacy label/route
  assertions were updated; follow-up verification also corrected the swarm
  toggle's explicit false accessibility state.
- Final UI precommit covered 124 tests; one new test incorrectly expected task
  creation to open a drawer. The corrected stage/card regression file passed
  all three tests. Creation now selects the new card's stage.
- Final native precommit: 57 tests, zero failures, including callback ownership,
  window replacement, shutdown bounds, trusted shortcut guards, page-load
  reinjection, and package resources.
- Native package smoke used a separate database and port 4140. Dock Quit and
  window close ran cleanup and stopped the runtime. Cmd+N toggled the sidebar
  once per press. Final Cmd+Q worked after a reload and navigation into Settings.
- Native board and Settings screenshots were inspected. The DMG passed
  `hdiutil verify`; the application plist passed `plutil -lint`.
- Ego Lite test space 16 remains with the user after a takeover. Browser checks
  of the new responsive design were not resumed; no sessions or cookies were
  cleared.

## macOS lifecycle

The desktop dependency hides a window when a tray object exists, even with
`on_close: :quit`. macOS therefore uses its Dock without a separate tray object.
Application-owned close and Quit callbacks replace dependency handlers in the
window process, which owns the wx event subscriptions.

WKWebView consumes Command-Q before wx menu accelerators. A native-only listener
handles trusted Command-Q in the application's origin, triggers a random private
navigation, and vetoes it in the native callback before requesting quit. It
exposes no HTTP shutdown route. The listener is reinstalled after page loads.
Cleanup is bounded; the coordinator and seven-second watchdog outlive application
group-leader shutdown.
