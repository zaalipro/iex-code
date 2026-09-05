# Orbital workspace redesign

## Goal

Completely redesign IexCode as a beautiful futuristic, space-inspired coding
workspace. The result must be visible throughout the application, not limited
to a theme swatch or a single screen.

## Visual direction

Deep, ink-blue surfaces; ice-cyan illumination; precise orbital geometry; light
reflection on navigation and dialogs; a clear hierarchy of rounded layers.
Space Grotesk titles add character while native body text and monospace code
preserve reading comfort. Sparse screens use composed orbital imagery built
with CSS and vector geometry, without invented activity or metrics.

The shared page header and compact toolbar remain the two title/control
patterns. The sidebar stays resizable, the composer stays compact until needed,
and title labels remain readable. Shadows and decorative effects are separately
controlled. Reduced motion takes priority over decorative animation.

## Coverage and proof

- Workspace shell, all navigation, Tasks, composer, model switcher, and dialogs.
- Mission Control, run ledger/details, fleet and truthful activity states.
- Research brief, levels, providers, report library, and report actions.
- Test Runner, Symbol Explorer, Changes, terminal, files, and chat components.
- Settings categories, preference rows, themes, depth settings, and save states.
- Standalone Workflow gallery, builder, details, and execution cockpit.
- All five persisted palettes, all four combinations of depth controls, reduced
  motion, desktop and narrow layouts, keyboard focus, and native shortcuts.

Verification must include the rendered app in Ego Lite, substantive interaction
checks with disposable data, relevant `mix precommit` coverage, independent
review, and a rebuilt macOS installer. Preserve the already authorized push and
installer delivery. Do not mark the active goal complete until these are done.

## Verified delivery evidence

- Ego Lite rendered the populated task board, Mission Control, Research,
  Consensus, Changes, file editor, terminal, chat, calendar, test runner, symbol
  explorer, workflow gallery/builder/details/cockpit, Settings, model picker,
  task dialog, and command palette using an isolated local QA database.
- All five theme previews and four independent shadow/effect combinations were
  exercised. Porcelain was saved and verified across navigation; Midnight was
  restored. A saved Shadows-off preference removed workflow-node shadows while
  its selected outline remained visible. Reduced motion removed spatial scale.
- Desktop and 760px views had no document overflow. Task stages scroll within
  their strip; Symbol Explorer and Test Runner retain rounded inset hosts.
  Sidebar keyboard resizing changed and persisted its width.
- Workflow search filtered the gallery and Clear restored it. Settings category
  navigation, save states, depth preview, and return navigation were checked.
  Consensus no longer invents sample reviewers, scores, messages, or approval.
- Final expanded `mix precommit`: **450 tests, 0 failures**, across 41 relevant
  files; warnings-as-errors compilation, dependency check, and formatting passed.
  This followed the full 3,275-test audit and corrections to its stale UI
  assertions. Two load-sensitive runtime failures passed isolated reruns; the
  large-payload test now exercises real exploration and compilation against an
  isolated small project instead of scanning/recompiling the development tree.
- Independent Astra visual review found no major header, radius, or contrast
  blockers in dark and light palettes.
- Production macOS ARM64 package built successfully. Native Cmd+N collapsed and
  reopened the sidebar; Cmd+Q completed teardown and released port 4144.
  `plutil -lint` and `hdiutil verify` passed.

QA used disposable data and did not launch external model work. Runtime logs
are under `/tmp/iex-orbital-*`; screenshots use descriptive filenames there.
