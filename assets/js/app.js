import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/iex_code"
import topbar from "../vendor/topbar"
import TerminalHook from "./hooks/terminal_hook"

// Theme behavior lives in the supported application bundle rather than an
// inline layout script, so CSP can remain strict in desktop and release builds.
const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.dataset.theme = systemTheme()
    document.documentElement.dataset.themeSource = "system"
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.dataset.theme = theme
    document.documentElement.dataset.themeSource = "user"
  }
}

setTheme(localStorage.getItem("phx:theme") || "system")
window.addEventListener("storage", (event) => event.key === "phx:theme" && setTheme(event.newValue || "system"))
window.addEventListener("phx:set-theme", (event) => setTheme(event.target.dataset.phxTheme))
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (document.documentElement.dataset.themeSource === "system") setTheme("system")
})

const Hooks = {
  TerminalHook,
  KeyboardSubmit: {
    mounted() {
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
        }
      })
    }
  },
  CodeCopy: {
    mounted() {
      // Snapshot the full innerHTML (icon + label) so the "Copied!" feedback
      // can be restored without destroying child elements such as SVG icons.
      this.originalHTML = this.el.innerHTML
      this.resetTimer = null
      this.el.addEventListener("click", () => {
        const text = this.el.getAttribute("data-code") || ""
        navigator.clipboard.writeText(text).then(() => {
          this.el.innerHTML = "Copied!"
          clearTimeout(this.resetTimer)
          this.resetTimer = setTimeout(() => {
            this.el.innerHTML = this.originalHTML
          }, 2000)
        })
      })
    },
    destroyed() {
      clearTimeout(this.resetTimer)
    }
  },
  CommandPalette: {
    mounted() {
      this.handleKeyDown = (e) => {
        // Cmd+K or Ctrl+K opens/toggles the palette
        if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
          e.preventDefault()
          this.pushEvent("toggle_command_palette", {})
          return
        }

        const palette = document.getElementById("command-palette-modal")
        if (!palette) return

        if (e.key === "Escape") {
          e.preventDefault()
          this.pushEvent("close_command_palette", {})
        } else if (e.key === "ArrowDown") {
          e.preventDefault()
          this.pushEvent("command_palette_navigate", {direction: "down"})
        } else if (e.key === "ArrowUp") {
          e.preventDefault()
          this.pushEvent("command_palette_navigate", {direction: "up"})
        } else if (e.key === "Enter") {
          e.preventDefault()
          this.pushEvent("command_palette_execute_selected", {})
        }
      }

      window.addEventListener("keydown", this.handleKeyDown)

      this.handleEvent("focus_palette_input", () => {
        setTimeout(() => {
          const input = document.getElementById("command-palette-input")
          if (input) {
            input.focus()
            input.select()
          }
        }, 30)
      })

      this.handleEvent("scroll_to_palette_item", ({index}) => {
        const el = document.getElementById(`palette-item-${index}`)
        if (el) {
          el.scrollIntoView({block: "nearest"})
        }
      })
    },
    destroyed() {
      window.removeEventListener("keydown", this.handleKeyDown)
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Top progress bar on page loads / navigations
topbar.config({barColors: {0: "#ff5e3a"}, shadowColor: "rgba(0, 0, 0, 0.3)"})
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300))
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide())

// Track the underlying Phoenix socket with its supported channel callbacks.
liveSocket.socket.onOpen(() => document.body.classList.remove("phx-disconnected"))
liveSocket.socket.onClose(() => document.body.classList.add("phx-disconnected"))
liveSocket.socket.onError(() => document.body.classList.add("phx-disconnected"))
window.addEventListener("offline", () => document.body.classList.add("phx-disconnected"))
window.addEventListener("online", () => document.body.classList.remove("phx-disconnected"))

liveSocket.connect()
window.liveSocket = liveSocket
