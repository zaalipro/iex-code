const storageKey = "iex-code:sidebar-width"
const defaultWidth = 256
const minimumWidth = 240
const maximumWidth = 440

export default {
  mounted() {
    this.sidebar = document.getElementById("workspace-sidebar")
    this.desktop = window.matchMedia("(min-width: 64rem)")
    this.preferredWidth = defaultWidth

    try {
      const saved = Number(localStorage.getItem(storageKey))
      if (Number.isFinite(saved) && saved >= minimumWidth) this.preferredWidth = saved
    } catch (_) { /* Browser storage can be unavailable. Resizing still works. */ }

    this.applyWidth = (requested, persist = false) => {
      const maximum = Math.min(maximumWidth, Math.floor(window.innerWidth * 0.4))
      const width = Math.round(Math.max(minimumWidth, Math.min(maximum, requested)))
      document.documentElement.style.setProperty("--workspace-sidebar-width", `${width}px`)
      this.el.setAttribute("aria-valuenow", width)
      this.el.setAttribute("aria-valuemax", maximum)
      if (persist) {
        this.preferredWidth = width
        try { localStorage.setItem(storageKey, String(width)) } catch (_) { /* Optional persistence. */ }
      }
    }

    this.onPointerDown = event => {
      if (event.button !== 0 || !this.desktop.matches) return
      event.preventDefault()
      this.dragStart = {x: event.clientX, width: this.sidebar.getBoundingClientRect().width}
      this.el.setPointerCapture(event.pointerId)
      this.el.focus()
      document.documentElement.classList.add("sidebar-resizing")
    }
    this.onPointerMove = event => {
      if (!this.dragStart) return
      this.applyWidth(this.dragStart.width + event.clientX - this.dragStart.x)
    }
    this.onPointerEnd = () => {
      if (!this.dragStart) return
      this.applyWidth(Number(this.el.getAttribute("aria-valuenow")), true)
      this.dragStart = null
      document.documentElement.classList.remove("sidebar-resizing")
    }
    this.onKeyDown = event => {
      if (!this.desktop.matches) return
      const width = Number(this.el.getAttribute("aria-valuenow"))
      const widths = {ArrowLeft: width - 16, ArrowRight: width + 16, Home: minimumWidth, End: maximumWidth}
      if (!(event.key in widths)) return
      event.preventDefault()
      this.applyWidth(widths[event.key], true)
    }
    this.onReset = () => this.applyWidth(defaultWidth, true)
    this.onViewportResize = () => {
      if (this.desktop.matches) this.applyWidth(this.preferredWidth)
    }

    this.onViewportResize()
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("pointermove", this.onPointerMove)
    this.el.addEventListener("lostpointercapture", this.onPointerEnd)
    this.el.addEventListener("pointerup", this.onPointerEnd)
    this.el.addEventListener("pointercancel", this.onPointerEnd)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("dblclick", this.onReset)
    window.addEventListener("resize", this.onViewportResize)
  },

  destroyed() {
    this.onPointerEnd()
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("pointermove", this.onPointerMove)
    this.el.removeEventListener("lostpointercapture", this.onPointerEnd)
    this.el.removeEventListener("pointerup", this.onPointerEnd)
    this.el.removeEventListener("pointercancel", this.onPointerEnd)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("dblclick", this.onReset)
    window.removeEventListener("resize", this.onViewportResize)
  }
}
