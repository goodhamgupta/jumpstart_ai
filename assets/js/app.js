// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Mention Hook for @ detection
let MentionHook = {
  mounted() {
    // Store state
    this.lastValue = this.el.value || ""
    this.lastCursorPos = 0
    this.lastAtIndex = -1
    
    this.el.addEventListener("input", e => {
      const value = e.target.value
      const cursorPos = e.target.selectionStart
      
      // Update state
      this.lastValue = value
      this.lastCursorPos = cursorPos
      
      // Find if we're in an @ mention context
      const beforeCursor = value.substring(0, cursorPos)
      const lastAtIndex = beforeCursor.lastIndexOf("@")
      
      if (lastAtIndex !== -1) {
        // Check if there's no space between @ and cursor
        const textAfterAt = beforeCursor.substring(lastAtIndex + 1)
        if (!textAfterAt.includes(" ") && !textAfterAt.includes("\n")) {
          // We're in a mention context
          this.lastAtIndex = lastAtIndex
          this.pushEvent("search_mentions", {query: textAfterAt})
          return
        }
      }
      
      // Not in mention context, hide suggestions
      this.pushEvent("hide_mentions", {})
    })
    
    // Handle arrow key navigation in mention suggestions
    this.handleEvent("navigate-mentions", ({key}) => {
      const suggestions = document.querySelectorAll("[data-mention-item]")
      const current = document.querySelector("[data-mention-item].bg-gray-100")
      
      if (suggestions.length === 0) return
      
      let newIndex = 0
      if (current) {
        const currentIndex = Array.from(suggestions).indexOf(current)
        if (key === "ArrowDown") {
          newIndex = (currentIndex + 1) % suggestions.length
        } else if (key === "ArrowUp") {
          newIndex = currentIndex - 1 < 0 ? suggestions.length - 1 : currentIndex - 1
        }
      }
      
      suggestions.forEach((el, idx) => {
        if (idx === newIndex) {
          el.classList.add("bg-gray-100")
        } else {
          el.classList.remove("bg-gray-100")
        }
      })
    })
    
    // Handle selecting current mention with Enter
    this.handleEvent("select-current-mention", () => {
      const selected = document.querySelector("[data-mention-item].bg-gray-100")
      if (selected) {
        selected.click()
      }
    })
    
    // Handle mention insertion
    this.handleEvent("insert-mention", ({text, query_length, current_value}) => {
      const textarea = this.el
      // Use provided current value or stored value
      const currentValue = current_value || this.lastValue || ""
      const atIndex = this.lastAtIndex
      
      if (atIndex !== -1 && currentValue) {
        // Replace @query with the mention text
        const before = currentValue.substring(0, atIndex)
        const after = currentValue.substring(atIndex + query_length)
        const newValue = before + text + " " + after
        
        // Update the textarea value
        textarea.value = newValue
        this.lastValue = newValue
        
        // Set cursor position after the inserted mention
        const newCursorPos = atIndex + text.length + 1
        
        // Use setTimeout to ensure the DOM has updated
        setTimeout(() => {
          textarea.focus()
          textarea.setSelectionRange(newCursorPos, newCursorPos)
          // Trigger input event after focus
          textarea.dispatchEvent(new Event("input", {bubbles: true}))
        }, 10)
      }
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {MentionHook}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// Handle clear-textarea events
window.addEventListener("phx:clear-textarea", e => {
  const textarea = document.getElementById("message-input")
  if (textarea) {
    textarea.value = ""
  }
})

// Handle scroll-to-bottom events
window.addEventListener("phx:scroll-to-bottom", e => {
  // Small delay to ensure DOM is updated
  setTimeout(() => {
    const messageContainer = document.getElementById("message-container")
    if (messageContainer) {
      const scrollableParent = messageContainer.closest('.overflow-y-auto')
      if (scrollableParent) {
        scrollableParent.scrollTop = scrollableParent.scrollHeight
      }
    }
  }, 50)
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

