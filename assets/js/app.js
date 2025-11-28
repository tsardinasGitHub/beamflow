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
// them using the `bare module specifier` format:
//
//     import "some-package"
//

import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// ============================================================================
// Workflow Graph Zoom/Pan Hook
// ============================================================================
const GraphZoomPan = {
  mounted() {
    this.zoom = 1
    this.minZoom = 0.25
    this.maxZoom = 3
    this.panX = 0
    this.panY = 0
    this.isDragging = false
    this.startX = 0
    this.startY = 0
    
    this.svg = this.el.querySelector('svg')
    this.viewport = this.el.querySelector('.graph-viewport')
    
    if (!this.svg) return
    
    // Mouse wheel zoom
    this.el.addEventListener('wheel', (e) => {
      e.preventDefault()
      
      const rect = this.el.getBoundingClientRect()
      const mouseX = e.clientX - rect.left
      const mouseY = e.clientY - rect.top
      
      const delta = e.deltaY > 0 ? -0.1 : 0.1
      const newZoom = Math.min(this.maxZoom, Math.max(this.minZoom, this.zoom + delta))
      
      if (newZoom !== this.zoom) {
        // Zoom towards mouse position
        const scale = newZoom / this.zoom
        this.panX = mouseX - (mouseX - this.panX) * scale
        this.panY = mouseY - (mouseY - this.panY) * scale
        this.zoom = newZoom
        this.updateTransform()
      }
    }, { passive: false })
    
    // Pan with mouse drag
    this.el.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return // Only left click
      this.isDragging = true
      this.startX = e.clientX - this.panX
      this.startY = e.clientY - this.panY
      this.el.classList.add('dragging')
      if (this.viewport) this.viewport.classList.add('dragging')
    })
    
    document.addEventListener('mousemove', (e) => {
      if (!this.isDragging) return
      this.panX = e.clientX - this.startX
      this.panY = e.clientY - this.startY
      this.updateTransform()
    })
    
    document.addEventListener('mouseup', () => {
      this.isDragging = false
      this.el.classList.remove('dragging')
      if (this.viewport) this.viewport.classList.remove('dragging')
    })
    
    // Touch support for mobile
    let lastTouchDistance = 0
    
    this.el.addEventListener('touchstart', (e) => {
      if (e.touches.length === 1) {
        this.isDragging = true
        this.startX = e.touches[0].clientX - this.panX
        this.startY = e.touches[0].clientY - this.panY
      } else if (e.touches.length === 2) {
        lastTouchDistance = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        )
      }
    }, { passive: true })
    
    this.el.addEventListener('touchmove', (e) => {
      if (e.touches.length === 1 && this.isDragging) {
        this.panX = e.touches[0].clientX - this.startX
        this.panY = e.touches[0].clientY - this.startY
        this.updateTransform()
      } else if (e.touches.length === 2) {
        const distance = Math.hypot(
          e.touches[0].clientX - e.touches[1].clientX,
          e.touches[0].clientY - e.touches[1].clientY
        )
        const scale = distance / lastTouchDistance
        this.zoom = Math.min(this.maxZoom, Math.max(this.minZoom, this.zoom * scale))
        lastTouchDistance = distance
        this.updateTransform()
      }
    }, { passive: true })
    
    this.el.addEventListener('touchend', () => {
      this.isDragging = false
    })
    
    // Zoom control buttons
    this.handleEvent("zoom_in", () => {
      this.zoom = Math.min(this.maxZoom, this.zoom + 0.25)
      this.updateTransform()
    })
    
    this.handleEvent("zoom_out", () => {
      this.zoom = Math.max(this.minZoom, this.zoom - 0.25)
      this.updateTransform()
    })
    
    this.handleEvent("zoom_reset", () => {
      this.zoom = 1
      this.panX = 0
      this.panY = 0
      this.updateTransform()
    })
    
    this.handleEvent("zoom_fit", () => {
      this.fitToContainer()
    })
    
    // Export SVG functionality
    this.handleEvent("export_svg", ({filename}) => {
      this.exportSVG(filename || "workflow-graph.svg")
    })
  },
  
  exportSVG(filename) {
    if (!this.svg) return
    
    // Clone the SVG to avoid modifying the original
    const svgClone = this.svg.cloneNode(true)
    
    // Remove interactive attributes and add styling
    svgClone.removeAttribute('phx-hook')
    svgClone.querySelectorAll('[phx-click]').forEach(el => {
      el.removeAttribute('phx-click')
      el.removeAttribute('phx-value-node-id')
    })
    
    // Add background color
    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect')
    rect.setAttribute('width', '100%')
    rect.setAttribute('height', '100%')
    rect.setAttribute('fill', '#1e293b') // slate-800
    svgClone.insertBefore(rect, svgClone.firstChild)
    
    // Add inline styles from CSS animations (simplified static version)
    svgClone.querySelectorAll('.graph-node-running').forEach(el => {
      el.style.filter = 'drop-shadow(0 0 8px rgba(59, 130, 246, 0.6))'
    })
    
    // Serialize and download
    const serializer = new XMLSerializer()
    let source = serializer.serializeToString(svgClone)
    
    // Add XML declaration and namespace
    if (!source.match(/^<\?xml/)) {
      source = '<?xml version="1.0" standalone="no"?>\r\n' + source
    }
    
    // Create blob and download
    const blob = new Blob([source], {type: 'image/svg+xml;charset=utf-8'})
    const url = URL.createObjectURL(blob)
    
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
  },
  
  updateTransform() {
    if (this.viewport) {
      this.viewport.style.transform = `translate(${this.panX}px, ${this.panY}px) scale(${this.zoom})`
    } else if (this.svg) {
      this.svg.style.transform = `translate(${this.panX}px, ${this.panY}px) scale(${this.zoom})`
    }
    
    // Update zoom level display
    const zoomDisplay = this.el.querySelector('.zoom-level')
    if (zoomDisplay) {
      zoomDisplay.textContent = `${Math.round(this.zoom * 100)}%`
    }
  },
  
  fitToContainer() {
    if (!this.svg) return
    
    const containerRect = this.el.getBoundingClientRect()
    const svgRect = this.svg.getBBox ? this.svg.getBBox() : { width: 800, height: 200 }
    
    const scaleX = (containerRect.width - 40) / svgRect.width
    const scaleY = (containerRect.height - 40) / svgRect.height
    this.zoom = Math.min(scaleX, scaleY, 1)
    
    this.panX = (containerRect.width - svgRect.width * this.zoom) / 2
    this.panY = (containerRect.height - svgRect.height * this.zoom) / 2
    
    this.updateTransform()
  }
}

// ============================================================================
// Node State Animation Hook
// ============================================================================
const NodeStateTracker = {
  mounted() {
    this.previousStates = new Map()
    this.trackStates()
  },
  
  updated() {
    this.trackStates()
  },
  
  trackStates() {
    const nodes = this.el.querySelectorAll('[data-node-state]')
    
    nodes.forEach(node => {
      const nodeId = node.dataset.nodeId
      const currentState = node.dataset.nodeState
      const previousState = this.previousStates.get(nodeId)
      
      if (previousState && previousState !== currentState) {
        // State changed! Apply transition animation
        node.classList.remove('graph-node-just-completed', 'graph-node-just-failed')
        
        if (currentState === 'completed' && previousState === 'running') {
          node.classList.add('graph-node-just-completed')
          // Remove animation class after it completes
          setTimeout(() => node.classList.remove('graph-node-just-completed'), 800)
        } else if (currentState === 'failed') {
          node.classList.add('graph-node-just-failed')
          setTimeout(() => node.classList.remove('graph-node-just-failed'), 600)
        }
      }
      
      this.previousStates.set(nodeId, currentState)
    })
  }
}

// ============================================================================
// Download Hook for Analytics Export
// ============================================================================
const DownloadHook = {
  mounted() {
    this.handleEvent("download", ({content, filename, mime}) => {
      const blob = new Blob([content], {type: mime})
      const url = URL.createObjectURL(blob)
      
      const link = document.createElement('a')
      link.href = url
      link.download = filename
      document.body.appendChild(link)
      link.click()
      document.body.removeChild(link)
      URL.revokeObjectURL(url)
    })
  }
}

// Register hooks
const Hooks = {
  GraphZoomPan,
  NodeStateTracker,
  DownloadHook
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

