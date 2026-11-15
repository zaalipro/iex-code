// Aurora Prism 60fps background canvas for the public /login dead view.
// Exits immediately on all authenticated pages where #owner-login-aurora-canvas is absent.

const STAR_TINTS = ["226, 232, 255", "165, 243, 252", "221, 214, 254"]

const STARS = Array.from({ length: 96 }, (_, i) => ({
  x: (i * 0.75487766) % 1,
  y: (i * 0.56984029) % 1,
  r: 0.55 + (i % 5) * 0.28,
  speed: 0.65 + (i % 5) * 0.32,
  phase: i * 0.91,
  tint: STAR_TINTS[i % STAR_TINTS.length],
}))

const AURORA_BANDS = [
  {
    y: 0.41,
    amp: 0.14,
    freq: 2.3,
    speed: 0.42,
    colorPeak: "rgba(99, 102, 241, 0.44)",
    colorEdge: "rgba(34, 211, 238, 0)",
  },
  {
    y: 0.49,
    amp: 0.16,
    freq: 1.85,
    speed: -0.34,
    colorPeak: "rgba(168, 85, 247, 0.46)",
    colorEdge: "rgba(168, 85, 247, 0)",
  },
  {
    y: 0.56,
    amp: 0.11,
    freq: 2.85,
    speed: 0.56,
    colorPeak: "rgba(34, 211, 238, 0.38)",
    colorEdge: "rgba(244, 63, 94, 0)",
  },
  {
    y: 0.61,
    amp: 0.09,
    freq: 2.1,
    speed: -0.48,
    colorPeak: "rgba(244, 63, 94, 0.25)",
    colorEdge: "rgba(0, 0, 0, 0)",
  },
]

const HORIZONTAL_STEPS = 64

function resizeCanvas(canvas) {
  const rect = canvas.getBoundingClientRect()
  const cssW = rect.width || window.innerWidth || 1280
  const cssH = rect.height || window.innerHeight || 720
  const dpr = Math.min(window.devicePixelRatio || 1, 2)
  const w = Math.max(1, Math.floor(cssW * dpr))
  const h = Math.max(1, Math.floor(cssH * dpr))

  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w
    canvas.height = h
  }

  return { w, h, dpr }
}

function drawAuroraFrame(ctx, w, h, dpr, t, px, py) {
  // Deep indigo cosmos base gradient
  const bg = ctx.createLinearGradient(0, 0, w, h)
  bg.addColorStop(0, "#05040c")
  bg.addColorStop(0.5, "#0a071a")
  bg.addColorStop(1, "#040814")
  ctx.fillStyle = bg
  ctx.fillRect(0, 0, w, h)

  // Soft upper-sky nebula halo reactive to parallax
  const nebula = ctx.createRadialGradient(
    w * (0.48 + px * 0.16),
    h * (0.28 + py * 0.1),
    0,
    w * 0.5,
    h * 0.36,
    Math.max(w, h) * 0.65
  )
  nebula.addColorStop(0, "rgba(99, 102, 241, 0.16)")
  nebula.addColorStop(0.42, "rgba(168, 85, 247, 0.07)")
  nebula.addColorStop(1, "rgba(0, 0, 0, 0)")
  ctx.fillStyle = nebula
  ctx.fillRect(0, 0, w, h)

  // Deterministic twinkling parallax starlight field
  for (let i = 0; i < STARS.length; i++) {
    const star = STARS[i]
    const twinkle = 0.25 + 0.65 * (0.5 + 0.5 * Math.sin(t * star.speed + star.phase))
    const depth = star.r * 0.03
    const sx = (((star.x + px * depth) % 1) + 1) % 1 * w
    const sy = (((star.y + py * depth) % 1) + 1) % 1 * h

    ctx.fillStyle = `rgba(${star.tint}, ${twinkle.toFixed(2)})`
    ctx.beginPath()
    ctx.arc(sx, sy, star.r * dpr, 0, Math.PI * 2)
    ctx.fill()
  }

  ctx.save()
  ctx.globalCompositeOperation = "screen"

  // Flowing multi-harmonic silk aurora curtains
  for (let idx = 0; idx < AURORA_BANDS.length; idx++) {
    const band = AURORA_BANDS[idx]
    ctx.beginPath()
    ctx.moveTo(0, h)

    for (let step = 0; step <= HORIZONTAL_STEPS; step++) {
      const u = step / HORIZONTAL_STEPS
      const x = u * w
      const primaryWave = Math.sin(u * Math.PI * band.freq + t * band.speed + idx * 1.05) * h * band.amp
      const secondaryWave = Math.cos(u * Math.PI * 1.35 - t * 0.3 + px * 2.4 + idx * 0.4) * h * 0.05
      const y = h * (band.y + py * 0.08) + primaryWave + secondaryWave
      ctx.lineTo(x, y)
    }

    ctx.lineTo(w, 0)
    ctx.lineTo(0, 0)
    ctx.closePath()

    const grad = ctx.createLinearGradient(0, h * 0.1, 0, h * 0.86)
    grad.addColorStop(0, "rgba(0, 0, 0, 0)")
    grad.addColorStop(0.44, band.colorPeak)
    grad.addColorStop(1, band.colorEdge)
    ctx.fillStyle = grad
    ctx.fill()
  }

  // Subtle vertical prism light curtains along the crest
  const prismCurtain = ctx.createRadialGradient(
    w * (0.52 + px * 0.1),
    h * (0.46 + py * 0.07),
    w * 0.02,
    w * 0.5,
    h * 0.48,
    Math.max(w, h) * 0.48
  )
  prismCurtain.addColorStop(0, "rgba(34, 211, 238, 0.14)")
  prismCurtain.addColorStop(0.45, "rgba(168, 85, 247, 0.08)")
  prismCurtain.addColorStop(1, "rgba(0, 0, 0, 0)")
  ctx.fillStyle = prismCurtain
  ctx.fillRect(0, 0, w, h)

  // Subtle fading perspective horizon grid
  ctx.strokeStyle = "rgba(165, 180, 252, 0.085)"
  ctx.lineWidth = Math.max(1, dpr * 0.75)

  const horizon = h * 0.68
  const vanishX = w * (0.5 + px * 0.12)
  const spokes = 13

  for (let i = -spokes; i <= spokes; i++) {
    ctx.beginPath()
    ctx.moveTo(vanishX, horizon)
    ctx.lineTo(vanishX + i * w * 0.16, h + 12)
    ctx.stroke()
  }

  for (let row = 1; row <= 6; row++) {
    const progress = Math.pow(row / 6, 1.8)
    const y = horizon + progress * (h - horizon)
    ctx.beginPath()
    ctx.moveTo(0, y)
    ctx.lineTo(w, y)
    ctx.stroke()
  }

  ctx.restore()
}

function initLoginAurora() {
  const canvas = document.getElementById("owner-login-aurora-canvas")
  if (!canvas || canvas.dataset.auroraBound === "true") return

  const ctx = canvas.getContext("2d")
  if (!ctx) return

  canvas.dataset.auroraBound = "true"

  const pointer = { tx: 0, ty: 0, x: 0, y: 0, active: false }
  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
  let rafId = null
  let metrics = resizeCanvas(canvas)

  const renderStatic = () => {
    metrics = resizeCanvas(canvas)
    drawAuroraFrame(ctx, metrics.w, metrics.h, metrics.dpr, 2.4, 0, 0)
  }

  const loop = (now) => {
    rafId = null
    if (document.hidden || motionQuery.matches) return

    const t = now * 0.001
    pointer.x += (pointer.tx - pointer.x) * 0.07
    pointer.y += (pointer.ty - pointer.y) * 0.07

    const px = pointer.active ? pointer.x : Math.sin(t * 0.35) * 0.08
    const py = pointer.active ? pointer.y : Math.cos(t * 0.25) * 0.05

    metrics = resizeCanvas(canvas)
    drawAuroraFrame(ctx, metrics.w, metrics.h, metrics.dpr, t, px, py)

    rafId = window.requestAnimationFrame(loop)
  }

  const startLoop = () => {
    if (motionQuery.matches) {
      if (rafId !== null) {
        window.cancelAnimationFrame(rafId)
        rafId = null
      }
      renderStatic()
      return
    }

    if (!document.hidden && rafId === null) {
      rafId = window.requestAnimationFrame(loop)
    }
  }

  window.addEventListener(
    "pointermove",
    (event) => {
      const vw = window.innerWidth || 1
      const vh = window.innerHeight || 1
      pointer.tx = event.clientX / vw - 0.5
      pointer.ty = event.clientY / vh - 0.5
      pointer.active = true
    },
    { passive: true }
  )

  const resetPointer = () => {
    pointer.tx = 0
    pointer.ty = 0
    pointer.active = false
  }

  window.addEventListener("mouseleave", resetPointer)
  window.addEventListener("blur", resetPointer)
  window.addEventListener("resize", () => {
    metrics = resizeCanvas(canvas)
    if (motionQuery.matches) renderStatic()
  })

  if (typeof ResizeObserver !== "undefined") {
    const observer = new ResizeObserver(() => {
      metrics = resizeCanvas(canvas)
      if (motionQuery.matches) renderStatic()
    })
    observer.observe(canvas)
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden && rafId !== null) {
      window.cancelAnimationFrame(rafId)
      rafId = null
    } else if (!document.hidden) {
      startLoop()
    }
  })

  if (typeof motionQuery.addEventListener === "function") {
    motionQuery.addEventListener("change", startLoop)
  }

  startLoop()
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initLoginAurora, { once: true })
} else {
  initLoginAurora()
}
