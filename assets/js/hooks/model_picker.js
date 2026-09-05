// LiveView owns the options. This hook only positions the native top-layer
// popover, so discovery updates keep flowing through normal LiveView patches.
export default {
  mounted() {
    this.trigger = document.getElementById("model-picker-trigger")
    this.position = () => {
      if (!this.trigger?.isConnected) return
      const rect = this.trigger.getBoundingClientRect()
      const viewport = window.visualViewport
      const leftEdge = viewport?.offsetLeft || 0
      const topEdge = viewport?.offsetTop || 0
      const width = viewport?.width || window.innerWidth
      const height = viewport?.height || window.innerHeight
      const gap = 8
      const menuWidth = Math.min(320, width - gap * 2)
      const above = rect.top - topEdge - gap * 2
      const below = topEdge + height - rect.bottom - gap * 2
      const placeAbove = above >= Math.min(300, this.el.scrollHeight) || above >= below
      const availableHeight = Math.max(0, placeAbove ? above : below)

      this.el.style.width = `${menuWidth}px`
      this.el.style.maxHeight = `${Math.min(384, availableHeight)}px`
      const menuHeight = this.el.getBoundingClientRect().height
      this.el.style.left = `${Math.max(leftEdge + gap, Math.min(rect.left, leftEdge + width - menuWidth - gap))}px`
      this.el.style.top = `${placeAbove ? rect.top - menuHeight - gap : rect.bottom + gap}px`
    }
    this.onKeyDown = event => {
      if (event.key === "Escape") {
        event.preventDefault()
        this.pushEvent("close_dropdowns", {})
        this.trigger?.focus()
      }
    }
    this.el.showPopover?.()
    this.position()
    this.observer = new ResizeObserver(this.position)
    this.observer.observe(this.el)
    this.observer.observe(this.trigger)
    const sidebar = document.getElementById("workspace-sidebar")
    if (sidebar) this.observer.observe(sidebar)
    window.addEventListener("resize", this.position)
    window.addEventListener("scroll", this.position, true)
    window.visualViewport?.addEventListener("resize", this.position)
    window.visualViewport?.addEventListener("scroll", this.position)
    window.addEventListener("keydown", this.onKeyDown)
  },

  updated() { this.position() },

  destroyed() {
    this.observer.disconnect()
    window.removeEventListener("resize", this.position)
    window.removeEventListener("scroll", this.position, true)
    window.visualViewport?.removeEventListener("resize", this.position)
    window.visualViewport?.removeEventListener("scroll", this.position)
    window.removeEventListener("keydown", this.onKeyDown)
  }
}
