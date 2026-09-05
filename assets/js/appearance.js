const themes = new Set(["midnight", "graphite", "aurora", "porcelain", "sandstone"])
const lightThemes = new Set(["porcelain", "sandstone"])

// Preferences come from the server-rendered document and public LiveView
// events. Browser-local dark-mode remnants never override saved app settings.
export const applyAppearance = preferences => {
  const root = document.documentElement
  const theme = themes.has(preferences.ui_theme) ? preferences.ui_theme : "midnight"
  root.dataset.uiTheme = theme
  root.dataset.theme = lightThemes.has(theme) ? "light" : "dark"
  root.dataset.depthShadows = String(preferences.shadows_3d !== false)
  root.dataset.depthEffects = String(preferences.effects_3d !== false)
  root.dataset.density = preferences.layout_density === "compact" ? "compact" : "comfortable"
  root.style.colorScheme = root.dataset.theme

  const background = getComputedStyle(root).getPropertyValue("--ui-bg").trim()
  const themeMeta = document.querySelector('meta[name="theme-color"]')
  if (background && themeMeta) themeMeta.content = background
  window.dispatchEvent(new CustomEvent("iex:appearance-applied", {detail: preferences}))
}

const root = document.documentElement
applyAppearance({
  ui_theme: root.dataset.uiTheme,
  shadows_3d: root.dataset.depthShadows !== "false",
  effects_3d: root.dataset.depthEffects !== "false",
  layout_density: root.dataset.density
})
window.addEventListener("phx:appearance_changed", event => applyAppearance(event.detail))

export const terminalTheme = () => {
  const style = getComputedStyle(document.documentElement)
  const value = name => style.getPropertyValue(name).trim()
  const dark = document.documentElement.dataset.theme !== "light"
  return {
    background: value("--ui-surface-inset"),
    foreground: value("--ui-text"),
    cursor: value("--ui-accent"),
    cursorAccent: value("--ui-bg"),
    selectionBackground: value("--ui-selection"),
    selectionForeground: value("--ui-text"),
    black: dark ? "#171a24" : "#242a35",
    red: value("--ui-danger"),
    green: value("--ui-success"),
    yellow: value("--ui-warning"),
    blue: value("--ui-info"),
    magenta: dark ? "#c49be8" : "#8251a7",
    cyan: dark ? "#72cfd0" : "#08777f",
    white: value("--ui-text"),
    brightBlack: value("--ui-subtle"),
    brightRed: value("--ui-danger"),
    brightGreen: value("--ui-success"),
    brightYellow: value("--ui-warning"),
    brightBlue: value("--ui-info"),
    brightMagenta: dark ? "#ddb4fa" : "#794092",
    brightCyan: dark ? "#97e5e3" : "#096d75",
    brightWhite: value("--ui-text")
  }
}
