import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/iex_code"
import topbar from "../vendor/topbar"

const Hooks = {
  AutoScroll: {
    mounted() {
      this.scrollToBottom()
    },
    updated() {
      this.scrollToBottom()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  },
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
      this.el.addEventListener("click", () => {
        const text = this.el.getAttribute("data-code") || ""
        navigator.clipboard.writeText(text).then(() => {
          const originalText = this.el.innerText
          this.el.innerText = "Copied!"
          setTimeout(() => {
            this.el.innerText = originalText
          }, 2000)
        })
      })
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

liveSocket.connect()
window.liveSocket = liveSocket

