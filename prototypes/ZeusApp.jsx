import { useEffect, useRef, useState } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import {
  Mic, MicOff, MessageCircle, Cpu, Home as House, Navigation, Volume2, Sun, Wifi,
  ChevronRight, ArrowUp, Bell, MapPin, QrCode, Power, Link2Off, Check, X,
  Database, Megaphone, Plus,
} from 'lucide-react'

/* ============================================================================
   ZEUS — Mobile App · Tier 2 · single-file prototype
   The operator-grade sibling of the Optimus consumer app. Same architecture
   (zeus-core embedded on the phone, providers direct, Mnemosyne synced with
   home nodes), rendered in the Zeus platform design language:
   Igneous Precision — crimson sentient orb, Orbitron / Rajdhani / JetBrains
   Mono, Mission-Control state badges (NOMINAL · REASONING · STREAMING),
   nodes instead of devices, approvals instead of suggestions.

   Demo: the LINK pill (top right) switches HOME-LAN ↔ REMOTE —
   the mobile node becomes authoritative and nothing stops working.

   Tabs: ZEUS (the agent) · SESSION · NODES
   Deps: react · framer-motion · lucide-react.
   ============================================================================ */

/* ── Igneous Precision palette — the crimson Zeus orb ── */
const C = {
  point: (i) => [Math.floor(185 + i * 70), Math.floor(45 + i * 150), Math.floor(15 + i * 55)],
  tipGlowInner: (i, a) => `rgba(255, ${Math.floor(80 + i * 90)}, 40, ${a})`,
  tipGlowOuter: 'rgba(255, 60, 20, 0)',
  wire: (a) => `rgba(255, 60, 20, ${a})`,
  dust: (a) => `rgba(255, 215, 185, ${a})`,
  glowStops: (a) =>
    [`rgba(255, 60, 20, ${a})`, `rgba(230, 45, 10, ${a * 0.5})`, `rgba(150, 25, 5, ${a * 0.15})`, 'rgba(0, 0, 0, 0)'],
  arc: (a) => `rgba(255, 145, 85, ${a})`,
}

/** The Zeus orb — verbatim renderer, phone-tuned density. */
function DeviceOrb({ mode, level = 0, frozen = false, style }) {
  const canvasRef = useRef(null)
  const modeRef = useRef(mode)
  const levelRef = useRef(level)
  const frozenRef = useRef(frozen)
  modeRef.current = mode
  levelRef.current = level
  frozenRef.current = frozen

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    let W = 0, H = 0, cx = 0, cy = 0
    let raf = 0
    let frozenFrame = null

    const resize = () => {
      const rect = canvas.getBoundingClientRect()
      W = rect.width; H = rect.height
      canvas.width = Math.round(W); canvas.height = Math.round(H)
      cx = W / 2; cy = H / 2
      state.baseRadius = Math.min(W, H) * 0.21
      frozenFrame = null
    }

    const state = {
      mode: modeRef.current, baseRadius: 80, time: Math.random() * 100,
      targetSpikeIntensity: 0.35, spikeIntensity: 0.35,
      targetGlow: 0.4, glow: 0.4,
      targetPulseSpeed: 1, pulseSpeed: 1,
      targetRotation: 0.3, rotation: 0.3,
      speakWave: 0, breathPhase: 0,
    }

    const makeParticle = () => {
      const angle = Math.random() * Math.PI * 2
      const dist = state.baseRadius * 1.4 + Math.random() * state.baseRadius * 2.5
      return {
        x: Math.cos(angle) * dist, y: Math.sin(angle) * dist,
        z: (Math.random() - 0.5) * dist * 1.5,
        size: Math.random() * 2.5 + 0.5, alpha: Math.random() * 0.5 + 0.1,
        speed: Math.random() * 0.003 + 0.001,
        orbitAngle: angle, orbitDist: dist, phase: Math.random() * Math.PI * 2,
      }
    }
    const particles = Array.from({ length: 110 }, makeParticle)

    const applyMode = (m) => {
      state.mode = m
      switch (m) {
        case 'dormant':
          state.targetSpikeIntensity = 0.28; state.targetGlow = 0.38
          state.targetPulseSpeed = 0.8; state.targetRotation = 0.22
          break
        case 'speaking':
          state.targetSpikeIntensity = 0.62; state.targetGlow = 0.9
          state.targetPulseSpeed = 3.2; state.targetRotation = 0.55
          break
        case 'thinking':
          state.targetSpikeIntensity = 0.3; state.targetGlow = 0.6
          state.targetPulseSpeed = 0.45; state.targetRotation = 0.13
          break
        case 'rage':
          state.targetSpikeIntensity = 1.0; state.targetGlow = 1.0
          state.targetPulseSpeed = 5; state.targetRotation = 1.2
          break
      }
    }
    applyMode(modeRef.current)
    let lastMode = modeRef.current

    const lerp = (a, b, t) => a + (b - a) * t

    const drawWireframe = (t) => {
      const r = state.baseRadius * 1.55
      const segments = 28, rings = 16
      const rotY = t * state.rotation * 0.4, rotX = t * state.rotation * 0.25
      const cosY = Math.cos(rotY), sinY = Math.sin(rotY)
      const cosX = Math.cos(rotX), sinX = Math.sin(rotX)
      ctx.strokeStyle = C.wire(0.06 + state.glow * 0.04)
      ctx.lineWidth = 0.5
      for (let i = 1; i < rings; i++) {
        const phi = (i / rings) * Math.PI
        const rr = r * Math.sin(phi), yy = r * Math.cos(phi)
        ctx.beginPath()
        for (let j = 0; j <= segments; j++) {
          const theta = (j / segments) * Math.PI * 2
          const x = rr * Math.cos(theta), z = rr * Math.sin(theta), y = yy
          const x2 = x * cosY - z * sinY, z2 = x * sinY + z * cosY
          const y2 = y * cosX - z2 * sinX, z3 = y * sinX + z2 * cosX
          const scale = 1 / (1 + z3 * 0.0008)
          j === 0 ? ctx.moveTo(cx + x2 * scale, cy + y2 * scale) : ctx.lineTo(cx + x2 * scale, cy + y2 * scale)
        }
        ctx.stroke()
      }
      for (let j = 0; j < segments; j += 2) {
        const theta = (j / segments) * Math.PI * 2
        ctx.beginPath()
        for (let i = 0; i <= rings; i++) {
          const phi = (i / rings) * Math.PI
          const x = r * Math.sin(phi) * Math.cos(theta)
          const z = r * Math.sin(phi) * Math.sin(theta)
          const y = r * Math.cos(phi)
          const x2 = x * cosY - z * sinY, z2 = x * sinY + z * cosY
          const y2 = y * cosX - z2 * sinX, z3 = y * sinX + z2 * cosX
          const scale = 1 / (1 + z3 * 0.0008)
          i === 0 ? ctx.moveTo(cx + x2 * scale, cy + y2 * scale) : ctx.lineTo(cx + x2 * scale, cy + y2 * scale)
        }
        ctx.stroke()
      }
    }

    const drawOrb = (t) => {
      const baseR = state.baseRadius
      const breath = Math.sin(state.breathPhase) * 0.04 + 1
      const r = baseR * breath
      const spikeH = r * state.spikeIntensity
      const latSteps = 34, lonSteps = 52
      const rotY = t * state.rotation, rotX = t * state.rotation * 0.6
      const cosRY = Math.cos(rotY), sinRY = Math.sin(rotY)
      const cosRX = Math.cos(rotX), sinRX = Math.sin(rotX)
      const lvl = levelRef.current
      const points = []
      for (let i = 0; i <= latSteps; i++) {
        const phi = (i / latSteps) * Math.PI
        for (let j = 0; j <= lonSteps; j++) {
          const theta = (j / lonSteps) * Math.PI * 2
          const n1 = Math.sin(phi * 8 + t * 2.5) * Math.cos(theta * 6 + t * 1.8)
          const n2 = Math.sin(phi * 12 - t * 3.2) * Math.cos(theta * 10 + t * 2.1)
          const n3 = Math.sin(phi * 4 + theta * 5 + t * 1.5)
          const speakNoise =
            state.mode === 'speaking'
              ? Math.sin(phi * 20 + t * 12) * Math.cos(theta * 15 + t * 8) * (state.speakWave * 0.4 + lvl * 0.5)
              : 0
          let displacement = n1 * 0.5 + n2 * 0.3 + n3 * 0.2 + speakNoise
          displacement = Math.max(0, displacement)
          const totalR = r + displacement * spikeH
          const x = totalR * Math.sin(phi) * Math.cos(theta)
          const z = totalR * Math.sin(phi) * Math.sin(theta)
          const y = totalR * Math.cos(phi)
          const x2 = x * cosRY - z * sinRY, z2 = x * sinRY + z * cosRY
          const y2 = y * cosRX - z2 * sinRX, z3 = y * sinRX + z2 * cosRX
          const depth = (z3 + r * 2) / (r * 4)
          points.push({ x: cx + x2, y: cy + y2, z: z3, depth, displacement })
        }
      }
      points.sort((a, b) => a.z - b.z)
      for (const p of points) {
        const intensity = p.displacement
        const depthFade = Math.max(0.1, p.depth)
        const [rC, gC, bC] = C.point(intensity)
        const alpha = depthFade * (0.4 + intensity * 0.6)
        const size = (1 + intensity * 3.5) * depthFade
        if (intensity > 0.5) {
          const glowR = size * (2 + state.glow * 3)
          const grad = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, glowR)
          grad.addColorStop(0, C.tipGlowInner(intensity, alpha * 0.5 * state.glow))
          grad.addColorStop(1, C.tipGlowOuter)
          ctx.fillStyle = grad
          ctx.fillRect(p.x - glowR, p.y - glowR, glowR * 2, glowR * 2)
        }
        ctx.fillStyle = `rgba(${rC}, ${gC}, ${bC}, ${alpha})`
        ctx.beginPath(); ctx.arc(p.x, p.y, size, 0, Math.PI * 2); ctx.fill()
      }
    }

    const drawParticles = (t) => {
      const rotSpeed = state.rotation * 0.5
      for (const p of particles) {
        p.orbitAngle += p.speed * rotSpeed
        const wobble = Math.sin(t * 2 + p.phase) * 8
        const x = Math.cos(p.orbitAngle) * p.orbitDist + wobble
        const y = p.y + Math.sin(t * 1.5 + p.phase) * 3
        const z = Math.sin(p.orbitAngle) * p.orbitDist * 0.6
        const scale = 1 / (1 + z * 0.001)
        const flicker = 0.5 + Math.sin(t * 3 + p.phase) * 0.5
        ctx.fillStyle = C.dust(p.alpha * flicker * (0.3 + state.glow * 0.7))
        ctx.fillRect(cx + x * scale - p.size * 0.5, cy + y * scale - p.size * 0.5, p.size * scale, p.size * scale)
      }
    }

    const drawCentralGlow = (t) => {
      const pulse = Math.sin(t * 2) * 0.15 + 0.85
      const r = state.baseRadius * (1.8 + state.glow * 0.8) * pulse
      const grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, r)
      const stops = C.glowStops(0.15 + state.glow * 0.25)
      grad.addColorStop(0, stops[0]); grad.addColorStop(0.3, stops[1])
      grad.addColorStop(0.6, stops[2]); grad.addColorStop(1, stops[3])
      ctx.fillStyle = grad
      ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fill()
    }

    const drawEnergyArcs = (t) => {
      if (state.glow < 0.5) return
      const numArcs = state.mode === 'rage' ? 8 : state.mode === 'speaking' ? 5 : 2
      const r = state.baseRadius * 0.9
      for (let a = 0; a < numArcs; a++) {
        const baseAngle = (a / numArcs) * Math.PI * 2 + t * 2
        ctx.beginPath()
        ctx.moveTo(cx + Math.cos(baseAngle) * r * 0.3, cy + Math.sin(baseAngle) * r * 0.3)
        for (let s = 1; s <= 6; s++) {
          const progress = s / 6
          const angle = baseAngle + Math.sin(t * 5 + a + s) * 0.8
          const dist = r * progress * 1.2
          ctx.lineTo(
            cx + Math.cos(angle) * dist + (Math.random() - 0.5) * 20,
            cy + Math.sin(angle) * dist + (Math.random() - 0.5) * 20,
          )
        }
        ctx.strokeStyle = C.arc((state.glow - 0.4) * 1.5 * (0.3 + Math.random() * 0.7))
        ctx.lineWidth = 1 + Math.random() * 1.5
        ctx.stroke()
      }
    }

    const animate = () => {
      raf = requestAnimationFrame(animate)
      if (frozenRef.current) {
        if (!frozenFrame) {
          ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H)
          drawCentralGlow(state.time); drawWireframe(state.time)
          drawParticles(state.time); drawOrb(state.time)
          frozenFrame = ctx.getImageData(0, 0, canvas.width, canvas.height)
        } else {
          ctx.putImageData(frozenFrame, 0, 0)
        }
        return
      }
      frozenFrame = null
      if (modeRef.current !== lastMode) { lastMode = modeRef.current; applyMode(lastMode) }
      const dt = 0.016
      state.time += dt * state.pulseSpeed
      state.breathPhase += dt * state.pulseSpeed * 1.5
      state.spikeIntensity = lerp(state.spikeIntensity, state.targetSpikeIntensity, 0.06)
      state.glow = lerp(state.glow, state.targetGlow, 0.06)
      state.pulseSpeed = lerp(state.pulseSpeed, state.targetPulseSpeed, 0.05)
      state.rotation = lerp(state.rotation, state.targetRotation, 0.05)
      if (state.mode === 'speaking') {
        state.speakWave = lerp(state.speakWave, 0.6 + Math.sin(state.time * 8) * 0.4, 0.1)
      } else {
        state.speakWave = lerp(state.speakWave, 0, 0.05)
      }
      ctx.fillStyle = 'rgba(0, 0, 0, 0.28)'
      ctx.fillRect(0, 0, W, H)
      const t = state.time
      drawCentralGlow(t); drawWireframe(t); drawParticles(t); drawOrb(t); drawEnergyArcs(t)
    }

    resize()
    window.addEventListener('resize', resize)
    raf = requestAnimationFrame(animate)
    return () => { cancelAnimationFrame(raf); window.removeEventListener('resize', resize) }
  }, [])

  return <canvas ref={canvasRef} style={{ display: 'block', ...style }} aria-label="Optimus orb" />
}

/* ── design tokens — Igneous Precision, mobile ── */
const FD = "'Orbitron', sans-serif"              // display: wordmark, badges, tab labels
const FB = "'Rajdhani', sans-serif"              // body
const FM = "'JetBrains Mono', monospace"         // data, meta, status lines
const ACC = '#ff5028'
const ACC2 = '#ff7838'
const GRN = '#3adf7c', YLW = '#ffd24a', BLU = '#4aa8ff'
const w = (a) => `rgba(255,255,255,${a})`
const r = (a) => `rgba(255,80,40,${a})`

const VOICE_DEMO = {
  question: 'Remind me to call Ali at six',
  answer: 'Done — reminder armed for 18:00.',
}

const PROPOSALS_HOME = [
  { id: 1, text: 'Order flowers for mom’s birthday next week?', from: 'PROMETHEUS · MNEMOSYNE · T-5MIN' },
  { id: 2, text: '15:00 moved to 15:30 — notify Alex of the delay?', from: 'PROMETHEUS · CALENDAR · NOW' },
]
const PROPOSALS_REMOTE = [
  { id: 3, text: 'Pharmacy in range — execute refill pickup reminder?', from: 'PROMETHEUS · GEO · NOW' },
  { id: 4, text: 'Route home congested after 18:00 — depart 17:30?', from: 'PROMETHEUS · CALENDAR+MAPS · T-12MIN' },
]

const ROUTES = [
  { id: 'auto', name: 'AUTO — NOUS ROUTES', meta: 'PER-REQUEST · COST/LATENCY AWARE', dot: '#3adf7c' },
  { id: 'anthropic', name: 'ANTHROPIC · OPUS 4.6', meta: 'P50 180MS · DIRECT', dot: '#3adf7c' },
  { id: 'openai', name: 'OPENAI · GPT-5.2', meta: 'P50 210MS · DIRECT', dot: '#3adf7c' },
  { id: 'google', name: 'GOOGLE · GEMINI 3.1 PRO', meta: 'P50 190MS · DIRECT', dot: '#3adf7c' },
  { id: 'xai', name: 'XAI · GROK 4.1', meta: 'P50 240MS · DIRECT', dot: '#3adf7c' },
  { id: 'groq', name: 'GROQ · LLAMA 4 MAVERICK', meta: 'P50 90MS · DIRECT', dot: '#3adf7c' },
  { id: 'deepseek', name: 'DEEPSEEK V4', meta: 'P50 320MS · DIRECT', dot: '#ffd24a' },
  { id: 'ollama', name: 'OLLAMA · HOME NODE', meta: 'LAN ONLY · FREE', dot: '#ffd24a' },
]

const BADGES = {
  ambient:    { text: 'NOMINAL',   color: GRN },
  listening:  { text: 'RECEIVING', color: ACC2 },
  thinking:   { text: 'REASONING', color: YLW },
  responding: { text: 'STREAMING', color: BLU },
}

/* label chip */
function Badge({ text, color }) {
  return (
    <span style={{ fontFamily: FD, fontSize: 8.5, fontWeight: 700, letterSpacing: '0.3em', color, border: `1px solid ${color}55`, background: `${color}14`, borderRadius: 4, padding: '4px 8px 3px 10px' }}>
      {text}
    </span>
  )
}

/* draggable slider */
function Slider({ value, onChange, Icon, disabled }) {
  const trackRef = useRef(null)
  const setFrom = (clientX) => {
    if (disabled) return
    const rect = trackRef.current.getBoundingClientRect()
    onChange(Math.round(Math.min(1, Math.max(0, (clientX - rect.left) / rect.width)) * 100))
  }
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, opacity: disabled ? 0.35 : 1 }}>
      <Icon size={17} color={ACC2} style={{ flexShrink: 0 }} />
      <div
        ref={trackRef}
        onPointerDown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); setFrom(e.clientX) }}
        onPointerMove={(e) => { if (e.buttons) setFrom(e.clientX) }}
        style={{ position: 'relative', height: 28, flex: 1, display: 'flex', alignItems: 'center', cursor: disabled ? 'default' : 'pointer', touchAction: 'none' }}
      >
        <div style={{ position: 'relative', height: 4, width: '100%', borderRadius: 2, background: w(0.09) }}>
          <div style={{ position: 'absolute', left: 0, top: 0, height: '100%', width: `${value}%`, borderRadius: 2, background: `linear-gradient(90deg, #c93010, ${ACC})` }} />
          <div style={{ position: 'absolute', left: `${value}%`, top: '50%', height: 16, width: 16, transform: 'translate(-50%,-50%)', borderRadius: 3, background: '#f5ede8', boxShadow: `0 0 10px ${r(0.5)}` }} />
        </div>
      </div>
      <span style={{ width: 30, textAlign: 'right', fontFamily: FM, fontSize: 11, color: w(0.45) }}>{String(value).padStart(3, '0')}</span>
    </div>
  )
}

/* settings row */
function Row({ icon: Icon, label, value, danger, onClick, last, disabled }) {
  return (
    <button
      onClick={disabled ? undefined : onClick}
      style={{
        display: 'flex', width: '100%', alignItems: 'center', gap: 12, padding: '13px 16px',
        background: 'none', border: 'none', borderBottom: last ? 'none' : `1px solid ${w(0.05)}`,
        cursor: onClick && !disabled ? 'pointer' : 'default', fontFamily: FB, textAlign: 'left',
        opacity: disabled ? 0.35 : 1,
      }}
    >
      <Icon size={16} color={danger ? '#ff4d4d' : ACC2} style={{ flexShrink: 0 }} />
      <span style={{ flex: 1, fontSize: 14.5, fontWeight: 600, letterSpacing: '0.04em', color: danger ? '#ff8a80' : '#f5ede8', textTransform: 'uppercase' }}>{label}</span>
      {value && <span style={{ fontFamily: FM, fontSize: 10.5, color: w(0.4) }}>{value}</span>}
      {onClick && !disabled && <ChevronRight size={14} color={w(0.3)} />}
    </button>
  )
}

export default function ZeusApp() {
  const [tab, setTab] = useState('zeus')             // zeus | session | nodes
  const [remote, setRemote] = useState(false)        // LINK: HOME-LAN ↔ REMOTE
  const [agentState, setAgentState] = useState('ambient')
  const [muted, setMuted] = useState(false)          // Optimus node mic
  const [volume, setVolume] = useState(65)
  const [brightness, setBrightness] = useState(80)
  const [level, setLevel] = useState(0)
  const [partial, setPartial] = useState('')
  const [resolvedVia, setResolvedVia] = useState(null)
  const [proposals, setProposals] = useState(PROPOSALS_HOME)
  const [toast, setToast] = useState(null)
  const [confirmRevoke, setConfirmRevoke] = useState(false)
  const [route, setRoute] = useState(ROUTES[0])
  const [routeSheet, setRouteSheet] = useState(false)
  const [messages, setMessages] = useState([
    { role: 'agent', text: 'Operator link established. All systems nominal — Kitchen node quiet. Standing by.' },
  ])
  const timers = useRef([])
  const later = (fn, ms) => timers.current.push(window.setTimeout(fn, ms))
  useEffect(() => () => timers.current.forEach(clearTimeout), [])

  const nodeOnline = !remote

  const switchLink = (nextRemote) => {
    setRemote(nextRemote)
    setProposals(nextRemote ? PROPOSALS_REMOTE : PROPOSALS_HOME)
    setResolvedVia(null)
    showToast(nextRemote ? 'REMOTE LINK — MOBILE NODE AUTHORITATIVE' : 'HOME LAN — OPTIMUS NODE LINKED')
  }

  useEffect(() => {
    if (agentState !== 'listening') return
    const id = setInterval(() => setLevel(Math.random() * 0.7 + 0.15), 90)
    return () => clearInterval(id)
  }, [agentState])

  const showToast = (text) => { setToast(text); later(() => setToast(null), 2800) }

  const runVoiceQuery = () => {
    if (agentState !== 'ambient') return
    setPartial(''); setResolvedVia(null)
    setAgentState('listening')
    const words = VOICE_DEMO.question.split(' ')
    words.forEach((_, i) => later(() => setPartial(words.slice(0, i + 1).join(' ')), 400 + i * 300))
    const listenMs = 400 + words.length * 300 + 600
    later(() => setAgentState('thinking'), listenMs)
    later(() => {
      setAgentState('responding')
      setResolvedVia(remote ? 'RESOLVED LOCAL · MOBILE NODE' : 'RESOLVED · SYNCED TO HOME NODE')
      setMessages((m) => [...m, { role: 'user', text: VOICE_DEMO.question }, { role: 'agent', text: VOICE_DEMO.answer }])
    }, listenMs + 1700)
    later(() => { setAgentState('ambient'); setPartial('') }, listenMs + 1700 + 3600)
  }

  const approve = (id) => { setProposals((s) => s.filter((x) => x.id !== id)); showToast('APPROVED — TASK DISPATCHED') }
  const deny = (id) => setProposals((s) => s.filter((x) => x.id !== id))

  const sendChat = (text) => {
    setMessages((m) => [...m, { role: 'user', text }])
    later(() => {
      setMessages((m) => [...m, { role: 'agent', text: '', streaming: true }])
      const reply = remote
        ? 'Executing on the mobile node — will sync state to home on next link.'
        : 'Executing — I’ll report back when it’s done.'
      reply.split(' ').forEach((_, i, arr) => {
        later(() => {
          setMessages((m) => {
            const copy = [...m]
            copy[copy.length - 1] = { role: 'agent', text: arr.slice(0, i + 1).join(' '), streaming: i < arr.length - 1 }
            return copy
          })
        }, 200 + i * 90)
      })
    }, 500)
  }

  const orbMode =
    agentState === 'listening' || agentState === 'responding' ? 'speaking'
    : agentState === 'thinking' ? 'thinking' : 'dormant'
  const badge = BADGES[agentState]
  const statusLine = agentState === 'ambient'
    ? (remote ? 'mobile node · zeus-core local' : 'linked · optimus node · kitchen')
    : agentState === 'listening' ? 'stt · receiving input'
    : agentState === 'thinking' ? 'nous · reasoning'
    : 'tts · streaming output'

  return (
    <div style={{ display: 'flex', minHeight: '100vh', alignItems: 'center', justifyContent: 'center', background: '#020202', padding: '28px 8px', fontFamily: FB }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@500;700;900&family=Rajdhani:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap');
        button{-webkit-tap-highlight-color:transparent}
        *{box-sizing:border-box}
        .zx-scroll::-webkit-scrollbar{display:none}
        @keyframes zx-scan{0%{transform:translateY(-100%)}100%{transform:translateY(780px)}}
      `}</style>

      {/* phone frame */}
      <div style={{ position: 'relative', width: 390, height: 780, borderRadius: 48, background: '#000', border: `1px solid ${r(0.2)}`, boxShadow: `0 0 90px ${r(0.08)}, 0 40px 90px rgba(0,0,0,0.85)`, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <div style={{ position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)', width: 118, height: 30, borderRadius: 20, background: '#0d0806', zIndex: 60 }} />

        {/* mission-control backdrop: crimson aurora + grid + scanline */}
        <div style={{
          pointerEvents: 'none', position: 'absolute', inset: 0,
          background:
            'radial-gradient(ellipse 70% 40% at 50% 22%, rgba(255,60,20,0.07), transparent 70%),' +
            'radial-gradient(ellipse 55% 35% at 50% 96%, rgba(230,45,10,0.04), transparent 70%)',
        }} />
        <div style={{
          pointerEvents: 'none', position: 'absolute', inset: 0, opacity: 0.5,
          backgroundImage: `linear-gradient(${r(0.045)} 1px, transparent 1px), linear-gradient(90deg, ${r(0.045)} 1px, transparent 1px)`,
          backgroundSize: '34px 34px',
        }} />
        <div style={{ pointerEvents: 'none', position: 'absolute', left: 0, right: 0, top: 0, height: 90, background: `linear-gradient(180deg, transparent, ${r(0.03)}, transparent)`, animation: 'zx-scan 7s linear infinite', zIndex: 1 }} />

        {/* toast */}
        <AnimatePresence>
          {toast && (
            <motion.div
              initial={{ opacity: 0, y: -14 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -14 }}
              style={{ position: 'absolute', top: 54, left: '50%', transform: 'translateX(-50%)', zIndex: 70, display: 'flex', alignItems: 'center', gap: 8, borderRadius: 6, background: 'rgba(20,8,4,0.96)', border: `1px solid ${r(0.4)}`, padding: '8px 14px', fontFamily: FM, fontSize: 10, letterSpacing: '0.08em', color: ACC2, whiteSpace: 'nowrap', maxWidth: 352 }}
            >
              <Check size={12} style={{ flexShrink: 0 }} /> <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{toast}</span>
            </motion.div>
          )}
        </AnimatePresence>

        {/* ── content ── */}
        <div className="zx-scroll" style={{ flex: 1, overflowY: 'auto', paddingTop: 54, scrollbarWidth: 'none', position: 'relative', zIndex: 2 }}>
          <AnimatePresence mode="wait">

            {/* ================= ZEUS — the agent ================= */}
            {tab === 'zeus' && (
              <motion.div key="zeus" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.25 }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 22px 0' }}>
                  <div style={{ fontFamily: FM, fontSize: 9.5, letterSpacing: '0.14em', color: w(0.35) }}>OPERATOR · MIGUEL</div>
                  <button
                    onClick={() => switchLink(!remote)}
                    style={{ display: 'flex', alignItems: 'center', gap: 6, borderRadius: 5, background: r(0.08), border: `1px solid ${r(remote ? 0.5 : 0.25)}`, padding: '6px 10px', fontFamily: FM, fontSize: 9, letterSpacing: '0.12em', color: remote ? ACC2 : w(0.6), cursor: 'pointer' }}
                  >
                    {remote ? <Navigation size={10} /> : <House size={10} />}
                    {remote ? 'LINK: REMOTE' : 'LINK: HOME-LAN'}
                  </button>
                </div>

                {/* the agent */}
                <div style={{ position: 'relative', display: 'flex', flexDirection: 'column', alignItems: 'center', marginTop: 0 }}>
                  <div style={{ position: 'relative', height: 250, width: 250, marginBottom: -34 }}>
                    <DeviceOrb mode={orbMode} level={level} style={{ height: '100%', width: '100%' }} />
                  </div>
                  <div style={{ marginTop: 4, textAlign: 'center', position: 'relative', zIndex: 3 }}>
                    <div style={{ fontFamily: FD, fontSize: 19, fontWeight: 700, letterSpacing: '0.42em', color: '#f5ede8', paddingLeft: '0.42em' }}>ZEUS</div>
                    <div style={{ marginTop: 7 }}>
                      <Badge text={badge.text} color={badge.color} />
                    </div>
                    <div style={{ marginTop: 7, fontFamily: FM, fontSize: 9.5, letterSpacing: '0.1em', color: w(0.38) }}>{statusLine}</div>
                    <button
                      onClick={() => setRouteSheet(true)}
                      style={{ marginTop: 8, display: 'inline-flex', alignItems: 'center', gap: 6, borderRadius: 5, background: r(0.07), border: `1px solid ${r(0.28)}`, padding: '5px 10px', fontFamily: FM, fontSize: 8.5, letterSpacing: '0.12em', color: ACC2, cursor: 'pointer' }}
                    >
                      <Cpu size={10} /> ROUTE · {route.name}
                    </button>
                    <div style={{ minHeight: 24, marginTop: 8, fontSize: 16, fontWeight: 500, color: w(0.75), padding: '0 30px', fontFamily: FB }}>
                      {agentState === 'listening' && (partial || '…')}
                      {agentState === 'responding' && VOICE_DEMO.answer}
                    </div>
                    <AnimatePresence>
                      {resolvedVia && agentState === 'ambient' && (
                        <motion.div
                          initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}
                          style={{ marginTop: 2, display: 'inline-flex', alignItems: 'center', gap: 6, borderRadius: 5, background: w(0.04), border: `1px solid ${w(0.08)}`, padding: '4px 10px', fontFamily: FM, fontSize: 8.5, letterSpacing: '0.1em', color: w(0.4) }}
                        >
                          <Cpu size={10} /> {resolvedVia}
                        </motion.div>
                      )}
                    </AnimatePresence>
                  </div>
                </div>

                {/* controls */}
                <div style={{ display: 'flex', justifyContent: 'center', gap: 14, marginTop: 14 }}>
                  <motion.button
                    onClick={runVoiceQuery}
                    whileTap={{ scale: 0.88 }}
                    animate={agentState === 'listening'
                      ? { boxShadow: [`0 0 26px ${r(0.4)}`, `0 0 46px ${r(0.85)}`, `0 0 26px ${r(0.4)}`], scale: [1, 1.06, 1] }
                      : { boxShadow: `0 0 26px ${r(0.4)}`, scale: 1 }}
                    transition={agentState === 'listening' ? { duration: 1.1, repeat: Infinity } : { duration: 0.3 }}
                    style={{ display: 'flex', height: 58, width: 58, alignItems: 'center', justifyContent: 'center', borderRadius: 14, border: `1px solid ${agentState === 'listening' ? ACC2 : ACC}`, cursor: 'pointer', background: agentState === 'listening' ? `linear-gradient(160deg, ${ACC2}, ${ACC})` : agentState !== 'ambient' ? 'rgba(255,80,40,0.15)' : `linear-gradient(160deg, ${ACC}, #c92808)`, opacity: agentState === 'thinking' || agentState === 'responding' ? 0.55 : 1 }}
                    aria-label="Comms"
                  >
                    <Mic size={23} color={agentState === 'thinking' || agentState === 'responding' ? ACC2 : '#180400'} />
                  </motion.button>
                  <motion.button
                    onClick={() => nodeOnline ? showToast('BROADCAST SENT — KITCHEN NODE') : showToast('NODE UNREACHABLE — QUEUED FOR NEXT LINK')}
                    whileTap={{ scale: 0.88, backgroundColor: 'rgba(255,80,40,0.22)' }}
                    style={{ display: 'flex', height: 58, width: 58, alignItems: 'center', justifyContent: 'center', borderRadius: 14, background: w(0.04), border: `1px solid ${r(0.25)}`, cursor: 'pointer', opacity: nodeOnline ? 1 : 0.4 }}
                    aria-label="Broadcast"
                  >
                    <Megaphone size={21} color={ACC2} />
                  </motion.button>
                  <motion.button
                    onClick={() => nodeOnline ? showToast('PING — KITCHEN NODE CHIMED') : showToast('NODE UNREACHABLE')}
                    whileTap={{ scale: 0.88, backgroundColor: 'rgba(255,80,40,0.22)' }}
                    style={{ display: 'flex', height: 58, width: 58, alignItems: 'center', justifyContent: 'center', borderRadius: 14, background: w(0.04), border: `1px solid ${r(0.25)}`, cursor: 'pointer', opacity: nodeOnline ? 1 : 0.4 }}
                    aria-label="Ping"
                  >
                    <MapPin size={21} color={ACC2} />
                  </motion.button>
                </div>
                <div style={{ display: 'flex', justifyContent: 'center', gap: 14, marginTop: 7 }}>
                  {['COMMS', 'BROADCAST', 'PING'].map((l) => (
                    <div key={l} style={{ width: 58, textAlign: 'center', fontFamily: FD, fontSize: 6.5, fontWeight: 700, letterSpacing: '0.22em', color: w(0.35) }}>{l}</div>
                  ))}
                </div>

                {/* approvals — Prometheus proposals */}
                <div style={{ padding: '22px 20px 8px' }}>
                  <div style={{ marginBottom: 10, display: 'flex', alignItems: 'center', gap: 7, fontFamily: FD, fontSize: 9, fontWeight: 700, letterSpacing: '0.3em', color: r(0.75) }}>
                    <Bell size={12} /> APPROVALS
                  </div>
                  <AnimatePresence>
                    {proposals.map((s) => (
                      <motion.div
                        key={s.id}
                        initial={{ opacity: 0, y: 10 }}
                        animate={{ opacity: 1, y: 0 }}
                        exit={{ opacity: 0, height: 0, marginBottom: 0, transition: { duration: 0.3 } }}
                        style={{ marginBottom: 10, borderRadius: 10, background: w(0.03), border: `1px solid ${r(0.16)}`, borderLeft: `2px solid ${ACC}`, padding: '13px 15px', overflow: 'hidden' }}
                      >
                        <div style={{ fontSize: 15.5, fontWeight: 600, lineHeight: 1.3, color: '#f5ede8', fontFamily: FB }}>{s.text}</div>
                        <div style={{ marginTop: 5, fontFamily: FM, fontSize: 8.5, letterSpacing: '0.1em', color: w(0.3) }}>{s.from}</div>
                        <div style={{ marginTop: 12, display: 'flex', gap: 8 }}>
                          <button
                            onClick={() => approve(s.id)}
                            style={{ display: 'flex', alignItems: 'center', gap: 6, borderRadius: 6, background: ACC, border: 'none', padding: '8px 16px', fontFamily: FD, fontSize: 9, fontWeight: 700, letterSpacing: '0.16em', color: '#180400', cursor: 'pointer' }}
                          >
                            <Check size={12} strokeWidth={3.5} /> APPROVE
                          </button>
                          <button
                            onClick={() => deny(s.id)}
                            style={{ display: 'flex', alignItems: 'center', gap: 6, borderRadius: 6, background: 'none', border: `1px solid ${w(0.12)}`, padding: '8px 14px', fontFamily: FD, fontSize: 9, fontWeight: 700, letterSpacing: '0.16em', color: w(0.45), cursor: 'pointer' }}
                          >
                            <X size={12} /> DENY
                          </button>
                        </div>
                      </motion.div>
                    ))}
                  </AnimatePresence>
                  {proposals.length === 0 && (
                    <div style={{ borderRadius: 10, background: w(0.02), border: `1px dashed ${w(0.1)}`, padding: '16px', fontFamily: FM, fontSize: 10, letterSpacing: '0.08em', color: w(0.3), textAlign: 'center' }}>
                      QUEUE EMPTY — PROMETHEUS WILL RAISE WHEN RELEVANT
                    </div>
                  )}
                </div>
              </motion.div>
            )}

            {/* ================= SESSION ================= */}
            {tab === 'session' && (
              <motion.div key="session" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.25 }} style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
                <SessionTab
                  messages={messages}
                  onSend={sendChat}
                  onVoice={() => { setTab('zeus'); later(runVoiceQuery, 350) }}
                  statusLine={remote ? 'MOBILE NODE · CORE LOCAL' : 'LINKED · KITCHEN NODE'}
                  badge={badge}
                />
              </motion.div>
            )}

            {/* ================= NODES ================= */}
            {tab === 'nodes' && (
              <motion.div key="nodes" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.25 }}>

                {/* mobile node — the core */}
                <div style={{ margin: '12px 20px 0', borderRadius: 12, background: `linear-gradient(150deg, ${r(0.07)}, rgba(255,255,255,0.02))`, border: `1px solid ${r(0.3)}`, overflow: 'hidden' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px 4px' }}>
                    <div style={{ display: 'flex', height: 38, width: 38, alignItems: 'center', justifyContent: 'center', borderRadius: 9, background: r(0.12), border: `1px solid ${r(0.3)}` }}>
                      <Cpu size={18} color={ACC2} />
                    </div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontFamily: FD, fontSize: 11, fontWeight: 700, letterSpacing: '0.2em', color: '#f5ede8' }}>MOBILE NODE</div>
                      <div style={{ marginTop: 2, fontFamily: FM, fontSize: 9, letterSpacing: '0.1em', color: r(0.7) }}>zeus-core 0.9 · this iphone</div>
                    </div>
                    <Badge text="ACTIVE" color={GRN} />
                  </div>
                  <div style={{ padding: '6px 2px 4px' }}>
                    <Row icon={Database} label="Mnemosyne" value={remote ? 'SYNC T-2MIN' : 'LIVE-LINK'} onClick={() => showToast('MNEMOSYNE CONSISTENT — NO DELTAS PENDING')} />
                    <Row icon={Wifi} label="Route" value={route.name} onClick={() => setRouteSheet(true)} last />
                  </div>
                </div>

                {/* optimus node */}
                <div style={{ margin: '12px 20px 0', borderRadius: 12, background: w(0.03), border: `1px solid ${w(0.08)}`, overflow: 'hidden' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px 6px' }}>
                    <div style={{ height: 44, width: 44 }}>
                      <DeviceOrb mode="dormant" frozen={muted || !nodeOnline} style={{ height: '100%', width: '100%', filter: muted || !nodeOnline ? 'saturate(.25) brightness(.6)' : 'none' }} />
                    </div>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontFamily: FD, fontSize: 11, fontWeight: 700, letterSpacing: '0.2em', color: '#f5ede8' }}>ZEUS NODE</div>
                      <div style={{ marginTop: 2, fontFamily: FM, fontSize: 9, letterSpacing: '0.1em', color: nodeOnline ? r(0.7) : w(0.3) }}>
                        {nodeOnline ? 'kitchen · lan · gateway 0.9' : 'unreachable · last seen t-12min'}
                      </div>
                    </div>
                    <Badge text={nodeOnline ? 'LINKED' : 'REMOTE'} color={nodeOnline ? GRN : YLW} />
                  </div>

                  {!nodeOnline && (
                    <div style={{ padding: '2px 16px 12px', fontFamily: FM, fontSize: 9.5, lineHeight: 1.7, letterSpacing: '0.04em', color: w(0.35) }}>
                      NODE AUTONOMOUS AT HOME · SAME AGENT, SAME MEMORY · MNEMOSYNE RECONCILES ON NEXT LINK
                    </div>
                  )}

                  {nodeOnline && (
                    <>
                      <div style={{ padding: '8px 16px 14px', display: 'flex', flexDirection: 'column', gap: 12 }}>
                        <Slider value={volume} onChange={setVolume} Icon={Volume2} />
                        <Slider value={brightness} onChange={setBrightness} Icon={Sun} />
                      </div>
                      <button
                        onClick={() => { setMuted((m) => !m); showToast(muted ? 'KITCHEN MIC — HOT' : 'KITCHEN MIC — COLD') }}
                        style={{ display: 'flex', width: '100%', alignItems: 'center', gap: 12, padding: '12px 16px', background: 'none', border: 'none', borderTop: `1px solid ${w(0.05)}`, cursor: 'pointer', fontFamily: FB }}
                      >
                        <MicOff size={16} color={muted ? '#ff4d4d' : ACC2} />
                        <span style={{ flex: 1, textAlign: 'left', fontSize: 14.5, fontWeight: 600, letterSpacing: '0.04em', color: '#f5ede8', textTransform: 'uppercase' }}>Microphone</span>
                        <span style={{ fontFamily: FM, fontSize: 9, letterSpacing: '0.14em', color: muted ? '#ff8a80' : GRN, border: `1px solid ${muted ? '#ff4d4d55' : GRN + '55'}`, borderRadius: 4, padding: '3px 8px' }}>
                          {muted ? 'COLD' : 'HOT'}
                        </span>
                      </button>
                    </>
                  )}

                  <Row icon={House} label="Sector" value="KITCHEN" onClick={() => showToast('SECTOR ASSIGNMENT WOULD OPEN')} disabled={!nodeOnline} />
                  <Row icon={QrCode} label="Pair code" onClick={() => showToast('PAIR CODE RAISED ON NODE DISPLAY')} disabled={!nodeOnline} />
                  <Row icon={MapPin} label="Ping node" onClick={() => showToast('PING — KITCHEN NODE CHIMED')} disabled={!nodeOnline} />
                  <Row icon={Power} label="Restart" onClick={() => showToast('NODE RESTART SEQUENCE INITIATED')} disabled={!nodeOnline} />
                  <Row icon={Link2Off} label="Revoke access" danger onClick={() => setConfirmRevoke(true)} last />
                </div>

                {/* add node */}
                <button
                  onClick={() => showToast('NODE ENROLLMENT — SCAN THE NEW DEVICE')}
                  style={{ display: 'flex', width: 'calc(100% - 40px)', margin: '12px 20px 0', alignItems: 'center', justifyContent: 'center', gap: 8, borderRadius: 12, border: `1px dashed ${r(0.3)}`, background: 'none', padding: '14px 0', fontFamily: FD, fontSize: 9.5, fontWeight: 700, letterSpacing: '0.2em', color: r(0.6), cursor: 'pointer' }}
                >
                  <Plus size={14} /> ENROLL NODE
                </button>

                <div style={{ padding: '18px 0 8px', textAlign: 'center', fontFamily: FM, fontSize: 8.5, letterSpacing: '0.14em', color: w(0.2) }}>
                  ZEUS · NOVAXAI
                </div>
              </motion.div>
            )}

          </AnimatePresence>
          <div style={{ height: 86 }} />
        </div>

        {/* ── route select sheet ── */}
        <AnimatePresence>
          {routeSheet && (
            <>
              <motion.div
                initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
                onClick={() => setRouteSheet(false)}
                style={{ position: 'absolute', inset: 0, zIndex: 80, background: 'rgba(0,0,0,0.75)' }}
              />
              <motion.div
                initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
                transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
                style={{ position: 'absolute', left: 10, right: 10, bottom: 12, zIndex: 90, borderRadius: 16, background: '#140805', border: `1px solid ${r(0.3)}`, padding: '20px 14px 12px', maxHeight: 560, display: 'flex', flexDirection: 'column' }}
              >
                <div style={{ fontFamily: FD, fontSize: 12, fontWeight: 700, letterSpacing: '0.24em', color: '#f5ede8', textAlign: 'center' }}>ROUTE SELECT</div>
                <div style={{ margin: '6px 0 12px', fontFamily: FM, fontSize: 8.5, letterSpacing: '0.1em', color: w(0.35), textAlign: 'center' }}>11 PROVIDERS ENROLLED · DIRECT FROM THIS NODE</div>
                <div className="zx-scroll" style={{ overflowY: 'auto', scrollbarWidth: 'none' }}>
                  {ROUTES.map((rt) => (
                    <button
                      key={rt.id}
                      onClick={() => { setRoute(rt); setRouteSheet(false); showToast(`ROUTE LOCKED — ${rt.name}`) }}
                      style={{ display: 'flex', width: '100%', alignItems: 'center', gap: 12, borderRadius: 10, background: route.id === rt.id ? r(0.1) : 'none', border: `1px solid ${route.id === rt.id ? r(0.4) : 'transparent'}`, padding: '12px 12px', cursor: 'pointer', fontFamily: FB, textAlign: 'left', marginBottom: 3 }}
                    >
                      <span style={{ height: 7, width: 7, borderRadius: 2, background: rt.dot, flexShrink: 0, boxShadow: `0 0 8px ${rt.dot}` }} />
                      <span style={{ flex: 1 }}>
                        <span style={{ display: 'block', fontFamily: FM, fontSize: 11, letterSpacing: '0.08em', color: '#f5ede8' }}>{rt.name}</span>
                        <span style={{ display: 'block', marginTop: 3, fontFamily: FM, fontSize: 8, letterSpacing: '0.1em', color: w(0.32) }}>{rt.meta}</span>
                      </span>
                      {route.id === rt.id && <Check size={15} color={ACC2} />}
                    </button>
                  ))}
                </div>
                <button
                  onClick={() => setRouteSheet(false)}
                  style={{ marginTop: 8, width: '100%', padding: '12px 0 4px', background: 'none', border: 'none', fontFamily: FD, fontSize: 9.5, fontWeight: 700, letterSpacing: '0.2em', color: w(0.4), cursor: 'pointer' }}
                >
                  CLOSE
                </button>
              </motion.div>
            </>
          )}
        </AnimatePresence>

        {/* ── revoke confirm sheet ── */}
        <AnimatePresence>
          {confirmRevoke && (
            <>
              <motion.div
                initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
                onClick={() => setConfirmRevoke(false)}
                style={{ position: 'absolute', inset: 0, zIndex: 80, background: 'rgba(0,0,0,0.75)' }}
              />
              <motion.div
                initial={{ y: '100%' }} animate={{ y: 0 }} exit={{ y: '100%' }}
                transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
                style={{ position: 'absolute', left: 10, right: 10, bottom: 12, zIndex: 90, borderRadius: 16, background: '#140805', border: `1px solid ${r(0.3)}`, padding: '24px 22px 16px', textAlign: 'center' }}
              >
                <div style={{ fontFamily: FD, fontSize: 13, fontWeight: 700, letterSpacing: '0.2em', color: '#f5ede8' }}>REVOKE KITCHEN NODE?</div>
                <div style={{ margin: '10px 0 20px', fontFamily: FM, fontSize: 9.5, lineHeight: 1.8, letterSpacing: '0.06em', color: w(0.4) }}>
                  PRINCIPAL TOKEN INVALIDATED · NODE CONTINUES AUTONOMOUS · RE-ENROLL VIA PAIR CODE
                </div>
                <button
                  onClick={() => { setConfirmRevoke(false); showToast('ACCESS REVOKED — RE-ENROLL TO RECONNECT') }}
                  style={{ display: 'flex', height: 48, width: '100%', alignItems: 'center', justifyContent: 'center', borderRadius: 8, background: '#e02020', border: 'none', fontFamily: FD, fontSize: 10.5, fontWeight: 700, letterSpacing: '0.22em', color: '#fff', cursor: 'pointer' }}
                >
                  REVOKE
                </button>
                <button
                  onClick={() => setConfirmRevoke(false)}
                  style={{ marginTop: 4, width: '100%', padding: '13px 0 4px', background: 'none', border: 'none', fontFamily: FD, fontSize: 9.5, fontWeight: 700, letterSpacing: '0.2em', color: w(0.4), cursor: 'pointer' }}
                >
                  ABORT
                </button>
              </motion.div>
            </>
          )}
        </AnimatePresence>

        {/* ── tab bar ── */}
        <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 50, display: 'flex', borderTop: `1px solid ${r(0.15)}`, background: 'rgba(3,2,2,0.94)', backdropFilter: 'blur(14px)', padding: '11px 0 20px' }}>
          {[
            { id: 'zeus', label: 'ZEUS', Icon: House },
            { id: 'session', label: 'SESSION', Icon: MessageCircle },
            { id: 'nodes', label: 'NODES', Icon: Cpu },
          ].map(({ id, label, Icon }) => (
            <button
              key={id}
              onClick={() => setTab(id)}
              style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, background: 'none', border: 'none', cursor: 'pointer' }}
            >
              <Icon size={19} color={tab === id ? ACC2 : w(0.35)} strokeWidth={tab === id ? 2.1 : 1.7} />
              <span style={{ fontFamily: FD, fontSize: 7, fontWeight: 700, letterSpacing: '0.28em', color: tab === id ? ACC2 : w(0.35) }}>{label}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

/* ================= SESSION TAB ================= */
function SessionTab({ messages, onSend, onVoice, statusLine, badge }) {
  const [input, setInput] = useState('')
  const scrollRef = useRef(null)
  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [messages])
  const send = () => {
    const t = input.trim()
    if (!t) return
    onSend(t)
    setInput('')
  }
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: 'calc(100vh)', maxHeight: 640 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '6px 20px 10px' }}>
        <div style={{ height: 34, width: 34 }}>
          <DeviceOrb mode="dormant" style={{ height: '100%', width: '100%' }} />
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontFamily: FD, fontSize: 11, fontWeight: 700, letterSpacing: '0.24em', color: '#f5ede8' }}>SESSION-01</div>
          <div style={{ marginTop: 2, fontFamily: FM, fontSize: 8.5, letterSpacing: '0.1em', color: r(0.65) }}>{statusLine}</div>
        </div>
        <Badge text={badge.text} color={badge.color} />
      </div>
      <div ref={scrollRef} className="zx-scroll" style={{ flex: 1, overflowY: 'auto', padding: '4px 18px', display: 'flex', flexDirection: 'column', gap: 10, scrollbarWidth: 'none' }}>
        {messages.map((m, i) => (
          <motion.div key={i} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} style={{ display: 'flex', justifyContent: m.role === 'user' ? 'flex-end' : 'flex-start', alignItems: 'flex-end', gap: 8 }}>
            {m.role === 'agent' && (
              <div style={{ height: 24, width: 24, flexShrink: 0, marginBottom: 2 }}>
                <DeviceOrb mode="dormant" style={{ height: '100%', width: '100%' }} />
              </div>
            )}
            <div style={{
              maxWidth: '78%', padding: '10px 14px', fontSize: 15, fontWeight: 500, lineHeight: 1.35, fontFamily: FB,
              ...(m.role === 'user'
                ? { borderRadius: '12px 12px 3px 12px', background: r(0.08), border: `1px solid ${r(0.25)}`, color: '#f5ede8' }
                : { borderRadius: '12px 12px 12px 3px', background: w(0.04), border: `1px solid ${w(0.07)}`, color: '#f5ede8' }),
            }}>
              {m.text}
              {m.streaming && (
                <motion.span
                  animate={{ opacity: [1, 0, 1] }}
                  transition={{ duration: 0.8, repeat: Infinity }}
                  style={{ marginLeft: 2, display: 'inline-block', height: 12, width: 2.5, transform: 'translateY(2px)', background: ACC2 }}
                />
              )}
            </div>
          </motion.div>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 16px 8px' }}>
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && send()}
          placeholder="> transmit to zeus…"
          style={{ flex: 1, height: 44, borderRadius: 8, background: w(0.04), border: `1px solid ${r(0.2)}`, outline: 'none', padding: '0 16px', fontFamily: FM, fontSize: 12, color: '#f5ede8' }}
        />
        {input.trim() ? (
          <button onClick={send} aria-label="Send" style={{ display: 'flex', height: 44, width: 44, alignItems: 'center', justifyContent: 'center', borderRadius: 10, background: `linear-gradient(160deg, ${ACC}, #c92808)`, border: 'none', cursor: 'pointer', flexShrink: 0 }}>
            <ArrowUp size={19} color="#180400" strokeWidth={2.5} />
          </button>
        ) : (
          <button onClick={onVoice} aria-label="Comms" style={{ display: 'flex', height: 44, width: 44, alignItems: 'center', justifyContent: 'center', borderRadius: 10, background: `linear-gradient(160deg, ${ACC}, #c92808)`, border: 'none', cursor: 'pointer', flexShrink: 0 }}>
            <Mic size={19} color="#180400" />
          </button>
        )}
      </div>
    </div>
  )
}
