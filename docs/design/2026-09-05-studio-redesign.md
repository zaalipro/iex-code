# IexCode Studio redesign

## Intent

Rebuild the desktop app's visual language as a polished macOS coding studio.
Keep every workflow, route, key element ID, accessibility interaction, and prior
sidebar/model-picker fix. This is an application redesign, not a marketing page.

## Appearance contract

Persist in AppSettings:

- `ui_theme`: `midnight` (default), `graphite`, `aurora`, `porcelain`, `sandstone`.
- `shadows_3d`: boolean, default true; controls elevation independently of movement.
- `effects_3d`: boolean, default true; controls decorative movement/perspective.

Use public-only `appearance:settings` PubSub payloads. A shared LiveView mount
hook publishes `appearance_changed` browser events. The root document sets
initial attributes so saved light themes render correctly on first paint.
Never include credentials in the appearance payload.

HTML attributes: `data-ui-theme`, `data-depth-shadows`, `data-depth-effects`,
`data-theme` (derived light/dark), and `data-density`.

## Visual language

- Midnight: inky navy and lavender. Graphite: neutral charcoal and coral.
- Aurora: dark forest and mint. Porcelain: cool white and blue.
- Sandstone: warm ivory and terracotta.
- Rounded controls (12px), cards (20px), dialogs (24px), deliberate spacing.
- SF Pro/system sans for navigation and prose; mono reserved for code/data.
- Clear selected states, visible keyboard focus, restrained layered depth.
- Shadow-off removes elevation. Effect-off removes decorative movement.
  Functional transforms (drag, centering, resize, drawer) remain intact.
- Reduced motion always suppresses decorative movement independently of settings.

## Work distribution and verification

1. Appearance settings agent: migration, settings defaults/validation/forms, theme
   gallery, independent switches, persistence and event regression tests.
2. Workspace agent: shell/navigation, board/composer, all workspace panels and
   dialogs. Preserve key IDs and behavior while applying semantic colors.
3. Theme agent: named palette variables, semantic Tailwind aliases, reusable
   rounded primitives, theme conversion of shared workflow/research/agent views.
4. Parent: root/live theme runtime, remaining legacy CSS integration, safe initial
   rendering, cross-screen theme checks, final review, precommit and macOS build.

Check all five themes, all four shadow/effect combinations, persistence through
navigation/reload, reduced motion, sidebar resizing, dropdowns, settings save,
workspace navigation, workflow editor, terminal, and responsive behavior.
Browser checks use Ego Lite in an isolated task space, closed after completion.

## Implemented structure

`assets/css/app.css` remains the supported Tailwind v4 entry point. Styles are
split into palette tokens (`themes.css`), existing application rules migrated to
semantic values (`application_base.css`), shared primitives and compatibility
rules (`studio_components.css`), workspace composition (`workspace_studio.css`),
and the Appearance studio (`appearance_settings.css`).

`IexCodeWeb.Appearance` exposes only four public settings and attaches a shared
LiveView hook. The root document uses saved settings before JavaScript runs;
`assets/js/appearance.js` applies the same contract to live updates. Xterm listens
for appearance updates and changes its canvas/ink/ANSI palette accordingly.

Independent reviewers checked the migration, privacy of event payloads, boolean
normalization, LiveView lifecycle, reduced motion, and light theme compatibility.
Visual QA corrected compact header icon sizing, palette placement in Settings,
hover-only background selectors, light Workflows surfaces, and toast overlap with
Save. The sidebar resizer and model menu retain their previously verified behavior.

## Browser verification

Using disposable local SQLite data in Ego Lite:

- Selected and saved all five named themes, verifying canvas and text colors.
- Verified all four combinations of 3D shadows and 3D effects against computed
  box-shadow and transform values. Both off reports `none` for each.
- Confirmed reduced motion removes the miniature's 3D transform.
- Confirmed a saved light theme persists across Settings/workspace navigation.
- Confirmed Workflows editor surfaces remain readable in Sandstone.
- Confirmed Consensus navigation and the top-layer model menu remain functional.
- At 390px viewport width, body does not overflow and mobile sidebar opens/closes.
- Save stays visible on long Settings screens and notifications do not cover it.

The dedicated web repository is unchanged by this desktop visual redesign.

## Final checks

- Full `mix precommit`: 3,262 tests, seven failures caused by legacy text/color
  expectations. Assertions now use board selectors, `aria-current`, and
  `aria-pressed` while preserving persistence and navigation checks.
- Final focused `mix precommit` covering affected files and appearance runtime:
  54 tests, zero failures. Earlier integrated appearance/workspace check:
  48 tests, zero failures.
- Production asset build, OTP release, .app assembly, and DMG creation passed.
- Packaged app migrated its disposable database, opened a native window, and
  saved Porcelain in Settings; the root attributes updated immediately.
