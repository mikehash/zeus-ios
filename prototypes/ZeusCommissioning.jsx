import { useEffect, useRef, useState, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import {
  ChevronLeft, Volume2, VolumeX, Check, ScanLine, Fingerprint, KeyRound,
  Zap, Cpu, ArrowRight,
} from 'lucide-react'

/* ============================================================================
   ZEUS — Mobile Onboarding · "Commissioning" · single-file prototype
   The operator boot sequence, made as frictionless as the consumer flow:
   initialize → operator auth → routes (managed or BYOK) → node enrollment
   (scan or skip — the core runs solo) → callsign → ALL SYSTEMS NOMINAL.

   The crimson orb is the guide: it speaks every step (real TTS when
   available, always captioned) in mission-control voice. One action per
   screen. Igneous Precision throughout.

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

/* ── tokens ── */
const FD = "'Orbitron', sans-serif"
const FB = "'Rajdhani', sans-serif"
const FM = "'JetBrains Mono', monospace"
const ACC = '#ff5028', ACC2 = '#ff7838'
const GRN = '#3adf7c'
const w = (a) => `rgba(255,245,240,${a})`
const r = (a) => `rgba(255,80,40,${a})`

const STEPS = ['welcome', 'auth', 'routes', 'nodes', 'callsign', 'done']

const NARRATION = {
  welcome: 'Zeus core is live on this phone. Commissioning takes under a minute — let’s light it up.',
  auth: 'First — you. Authenticate as operator.',
  routes: 'Now my brainstem. Pick how I reach the models.',
  nodes: 'Any hardware to enroll? Scan a node — or skip. I run fine solo.',
  callsign: 'Last thing. What do I call you on comms?',
  done: 'All systems nominal. I’m yours, operator.',
}

const primaryBtn = {
  display: 'flex', height: 52, width: '100%', alignItems: 'center', justifyContent: 'center', gap: 10,
  borderRadius: 10, background: `linear-gradient(160deg, ${ACC}, #c92808)`, border: `1px solid ${ACC}`,
  fontFamily: FD, fontSize: 11, fontWeight: 700, letterSpacing: '0.24em', color: '#180400',
  cursor: 'pointer', boxShadow: `0 0 24px ${r(0.35)}`,
}
const quietBtn = {
  display: 'block', width: '100%', marginTop: 4, padding: '14px 0 0', fontFamily: FD, fontSize: 9,
  fontWeight: 700, letterSpacing: '0.22em', color: w(0.35), background: 'none', border: 'none', cursor: 'pointer',
}

export default function ZeusCommissioning() {
  const [started, setStarted] = useState(false)
  const [step, setStep] = useState('welcome')
  const [voiceOn, setVoiceOn] = useState(true)
  const [caption, setCaption] = useState('')
  const [speaking, setSpeaking] = useState(false)
  const [authed, setAuthed] = useState(false)
  const [routeMode, setRouteMode] = useState(null)   // 'managed' | 'byok'
  const [nodeFound, setNodeFound] = useState(false)
  const [solo, setSolo] = useState(false)
  const [callsign, setCallsign] = useState('MIGUEL')
  const timers = useRef([])
  const voiceOnRef = useRef(voiceOn)
  voiceOnRef.current = voiceOn

  const later = (fn, ms) => timers.current.push(window.setTimeout(fn, ms))
  const clearTimers = () => { timers.current.forEach(clearTimeout); timers.current = [] }
  useEffect(() => () => { clearTimers(); try { window.speechSynthesis?.cancel() } catch {} }, [])

  const narrate = useCallback((text) => {
    clearTimers()
    try { window.speechSynthesis?.cancel() } catch {}
    setCaption('')
    setSpeaking(true)
    const words = text.split(' ')
    words.forEach((_, i) => later(() => setCaption(words.slice(0, i + 1).join(' ')), 260 + i * 225))
    later(() => setSpeaking(false), 260 + words.length * 225 + 500)
    if (voiceOnRef.current && typeof window !== 'undefined' && window.speechSynthesis) {
      try {
        const u = new SpeechSynthesisUtterance(text)
        u.rate = 1.0
        u.pitch = 0.9
        const voices = window.speechSynthesis.getVoices()
        const pick =
          voices.find((v) => /Daniel|Alex|Google UK English Male|Aaron/i.test(v.name)) ||
          voices.find((v) => v.lang?.startsWith('en'))
        if (pick) u.voice = pick
        window.speechSynthesis.speak(u)
      } catch {}
    }
  }, [])

  useEffect(() => {
    if (!started) return
    narrate(NARRATION[step])
  }, [started, step, narrate])

  /* AUTH: passkey tap → verified pulse → advance */
  const doAuth = () => {
    setAuthed(true)
    later(() => setStep('routes'), 1200)
  }

  /* NODES: simulate scan */
  useEffect(() => {
    if (step !== 'nodes') { setNodeFound(false); return }
    const t = setTimeout(() => setNodeFound(true), 3200)
    const t2 = setTimeout(() => setStep('callsign'), 4400)
    return () => { clearTimeout(t); clearTimeout(t2) }
  }, [step])

  const skipNodes = () => { clearTimers(); setSolo(true); setNodeFound(false); setStep('callsign') }

  const stepIdx = STEPS.indexOf(step)
  const back = () => { const i = STEPS.indexOf(step); if (i > 0) setStep(STEPS[i - 1]) }
  const toggleVoice = () => setVoiceOn((v) => { if (v) { try { window.speechSynthesis?.cancel() } catch {} } return !v })

  const orbSize = step === 'welcome' || step === 'done' ? 290 : 185
  const orbMode = step === 'done' ? (speaking ? 'speaking' : 'dormant') : speaking ? 'speaking' : step === 'nodes' ? 'thinking' : 'dormant'

  return (
    <div style={{ display: 'flex', minHeight: '100vh', alignItems: 'center', justifyContent: 'center', background: '#020202', padding: '28px 8px', fontFamily: FB }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@500;700;900&family=Rajdhani:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap');
        @keyframes zob-scan{0%{top:12%}50%{top:84%}100%{top:12%}}
        button{-webkit-tap-highlight-color:transparent}
        *{box-sizing:border-box}
        input::placeholder{color:rgba(255,245,240,.2)}
      `}</style>

      {/* phone frame */}
      <div style={{ position: 'relative', width: 390, height: 780, borderRadius: 48, background: '#000', border: `1px solid ${r(0.2)}`, boxShadow: `0 0 90px ${r(0.07)}, 0 40px 90px rgba(0,0,0,0.85)`, overflow: 'hidden' }}>
        <div style={{ position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)', width: 118, height: 30, borderRadius: 20, background: '#0d0806', zIndex: 60 }} />

        {/* backdrop: aurora + grid */}
        <div style={{
          pointerEvents: 'none', position: 'absolute', inset: 0,
          background:
            'radial-gradient(ellipse 70% 45% at 50% 30%, rgba(255,60,20,0.07), transparent 70%),' +
            'radial-gradient(ellipse 55% 40% at 50% 92%, rgba(230,45,10,0.04), transparent 70%)',
        }} />
        <div style={{
          pointerEvents: 'none', position: 'absolute', inset: 0, opacity: 0.45,
          backgroundImage: `linear-gradient(${r(0.04)} 1px, transparent 1px), linear-gradient(90deg, ${r(0.04)} 1px, transparent 1px)`,
          backgroundSize: '34px 34px',
        }} />

        {/* ── splash gate ── */}
        <AnimatePresence>
          {!started && (
            <motion.button
              exit={{ opacity: 0, transition: { duration: 0.6 } }}
              onClick={() => setStarted(true)}
              style={{ position: 'absolute', inset: 0, zIndex: 50, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', background: '#000', border: 'none', cursor: 'pointer', fontFamily: FB }}
            >
              <div style={{ height: 310, width: 310, marginBottom: -34 }}>
                <DeviceOrb mode="dormant" style={{ height: '100%', width: '100%' }} />
              </div>
              <div style={{ position: 'relative', zIndex: 3, fontFamily: FD, fontSize: 21, fontWeight: 700, letterSpacing: '0.5em', paddingLeft: '0.5em', color: '#f5ede8' }}>ZEUS</div>
              <motion.div
                animate={{ opacity: [0.3, 0.85, 0.3] }}
                transition={{ duration: 2.2, repeat: Infinity }}
                style={{ marginTop: 24, fontFamily: FD, fontSize: 9, fontWeight: 700, letterSpacing: '0.34em', color: r(0.75) }}
              >
                TAP TO INITIALIZE
              </motion.div>
              <div style={{ position: 'absolute', bottom: 26, fontFamily: FM, fontSize: 8.5, letterSpacing: '0.16em', color: w(0.22) }}>NOVAXAI · ZEUS-CORE 0.9</div>
            </motion.button>
          )}
        </AnimatePresence>

        {/* ── header ── */}
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, zIndex: 40, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '58px 20px 0' }}>
          <button
            onClick={back}
            aria-label="Back"
            style={{ display: 'flex', height: 34, width: 34, alignItems: 'center', justifyContent: 'center', borderRadius: 9, background: w(0.04), border: `1px solid ${r(0.2)}`, color: w(0.6), cursor: 'pointer', visibility: stepIdx > 0 && step !== 'done' ? 'visible' : 'hidden' }}
          >
            <ChevronLeft size={17} />
          </button>
          <div style={{ display: 'flex', gap: 6 }}>
            {STEPS.map((s, i) => (
              <div key={s} style={{ height: 4, width: i === stepIdx ? 20 : 5, borderRadius: 2, background: i <= stepIdx ? ACC : w(0.12), transition: 'all .35s' }} />
            ))}
          </div>
          <button
            onClick={toggleVoice}
            aria-label="Toggle voice"
            style={{ display: 'flex', height: 34, width: 34, alignItems: 'center', justifyContent: 'center', borderRadius: 9, background: voiceOn ? r(0.1) : w(0.04), border: `1px solid ${voiceOn ? r(0.4) : r(0.2)}`, color: voiceOn ? ACC2 : w(0.4), cursor: 'pointer' }}
          >
            {voiceOn ? <Volume2 size={15} /> : <VolumeX size={15} />}
          </button>
        </div>

        {/* ── the orb ── */}
        <motion.div
          animate={{ height: orbSize, width: orbSize }}
          transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
          style={{ position: 'absolute', top: 96, left: '50%', transform: 'translateX(-50%)', zIndex: 10 }}
        >
          <DeviceOrb mode={orbMode} style={{ height: '100%', width: '100%' }} />
        </motion.div>

        {/* ── caption ── */}
        <div style={{ position: 'absolute', top: orbSize === 290 ? 372 : 274, left: 0, right: 0, zIndex: 12, padding: '0 32px', textAlign: 'center', transition: 'top .7s cubic-bezier(.22,1,.36,1)' }}>
          <p style={{ margin: 0, minHeight: 88, fontSize: 21, fontWeight: 600, lineHeight: 1.35, letterSpacing: '0.01em', color: w(0.92), fontFamily: FB }}>
            {caption}
            {speaking && (
              <motion.span
                animate={{ opacity: [1, 0, 1] }}
                transition={{ duration: 0.8, repeat: Infinity }}
                style={{ marginLeft: 3, display: 'inline-block', height: 17, width: 2.5, transform: 'translateY(2px)', background: ACC2 }}
              />
            )}
          </p>
        </div>

        {/* ── per-step content ── */}
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 20, padding: '0 24px 28px' }}>
          <AnimatePresence mode="wait">

            {step === 'welcome' && started && (
              <StepWrap key="welcome">
                <button style={primaryBtn} onClick={() => setStep('auth')}>INITIALIZE <ArrowRight size={14} /></button>
              </StepWrap>
            )}

            {step === 'auth' && (
              <StepWrap key="auth">
                <AnimatePresence mode="wait">
                  {!authed ? (
                    <motion.div key="a1" exit={{ opacity: 0 }}>
                      <button style={primaryBtn} onClick={doAuth}><Fingerprint size={16} /> CONTINUE WITH PASSKEY</button>
                      <button style={quietBtn} onClick={doAuth}>USE NOVAXAI ID</button>
                    </motion.div>
                  ) : (
                    <motion.div key="a2" initial={{ opacity: 0, scale: 0.95 }} animate={{ opacity: 1, scale: 1 }}
                      style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, borderRadius: 10, border: `1px solid ${GRN}55`, background: `${GRN}10`, padding: '15px 0' }}>
                      <Check size={16} color={GRN} strokeWidth={3} />
                      <span style={{ fontFamily: FM, fontSize: 10.5, letterSpacing: '0.16em', color: GRN }}>OPERATOR VERIFIED · MIGUEL</span>
                    </motion.div>
                  )}
                </AnimatePresence>
              </StepWrap>
            )}

            {step === 'routes' && (
              <StepWrap key="routes">
                {[
                  { id: 'managed', Icon: Zap, title: 'MANAGED — NOVA CREDITS', desc: '11 routes, zero keys. Metered via Atlas. Recommended.' },
                  { id: 'byok', Icon: KeyRound, title: 'BYOK — OWN KEYS', desc: 'Direct to providers. Keys stay in the secure enclave.' },
                ].map(({ id, Icon, title, desc }) => (
                  <button
                    key={id}
                    onClick={() => setRouteMode(id)}
                    style={{
                      display: 'flex', width: '100%', alignItems: 'flex-start', gap: 13, borderRadius: 12, padding: '14px 15px',
                      marginBottom: 8, cursor: 'pointer', fontFamily: FB, textAlign: 'left',
                      background: routeMode === id ? r(0.1) : w(0.03),
                      border: `1px solid ${routeMode === id ? ACC : r(0.16)}`,
                    }}
                  >
                    <Icon size={17} color={ACC2} style={{ marginTop: 2, flexShrink: 0 }} />
                    <span style={{ flex: 1 }}>
                      <span style={{ display: 'block', fontFamily: FD, fontSize: 10, fontWeight: 700, letterSpacing: '0.16em', color: '#f5ede8' }}>{title}</span>
                      <span style={{ display: 'block', marginTop: 4, fontSize: 13.5, fontWeight: 500, lineHeight: 1.35, color: w(0.5) }}>{desc}</span>
                    </span>
                    {routeMode === id && <Check size={15} color={ACC2} style={{ marginTop: 2 }} />}
                  </button>
                ))}
                <AnimatePresence>
                  {routeMode === 'byok' && (
                    <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} style={{ overflow: 'hidden' }}>
                      <input
                        defaultValue="sk-ant-••••••••••••••••"
                        style={{ width: '100%', height: 46, borderRadius: 9, background: w(0.04), border: `1px solid ${r(0.25)}`, outline: 'none', padding: '0 15px', fontFamily: FM, fontSize: 11.5, color: '#f5ede8', marginBottom: 8 }}
                      />
                      <div style={{ fontFamily: FM, fontSize: 8.5, letterSpacing: '0.1em', color: w(0.3), marginBottom: 8, textAlign: 'center' }}>MORE ROUTES ANYTIME IN NODES → ROUTE</div>
                    </motion.div>
                  )}
                </AnimatePresence>
                <button
                  style={{ ...primaryBtn, opacity: routeMode ? 1 : 0.35, pointerEvents: routeMode ? 'auto' : 'none' }}
                  onClick={() => setStep('nodes')}
                >
                  {routeMode === 'byok' ? 'VALIDATE + CONTINUE' : 'CONTINUE'} <ArrowRight size={14} />
                </button>
              </StepWrap>
            )}

            {step === 'nodes' && (
              <StepWrap key="nodes">
                {/* viewfinder */}
                <div style={{ position: 'relative', margin: '0 auto 16px', height: 190, width: 250, borderRadius: 14, overflow: 'hidden', background: 'linear-gradient(160deg,#160a06,#080302)', border: `1px solid ${r(0.15)}` }}>
                  <div style={{ position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%,-50%)', width: 158, height: 95, borderRadius: 6, background: '#0a0402', border: `1px solid ${r(0.3)}`, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12, padding: 10 }}>
                    <div style={{ height: 42, width: 42 }}><DeviceOrb mode="dormant" style={{ height: '100%', width: '100%' }} /></div>
                    <div style={{ height: 50, width: 50, borderRadius: 4, background: '#f5ede8', display: 'grid', gridTemplateColumns: 'repeat(5,1fr)', gap: 1.5, padding: 5 }}>
                      {[1,0,1,1,0,0,1,0,1,1,1,1,0,0,1,0,1,1,0,1,1,0,0,1,1].map((b, i) => (
                        <div key={i} style={{ background: b ? '#140805' : 'transparent' }} />
                      ))}
                    </div>
                  </div>
                  {[
                    { top: 10, left: 10, borderTop: `2px solid ${ACC}`, borderLeft: `2px solid ${ACC}` },
                    { top: 10, right: 10, borderTop: `2px solid ${ACC}`, borderRight: `2px solid ${ACC}` },
                    { bottom: 10, left: 10, borderBottom: `2px solid ${ACC}`, borderLeft: `2px solid ${ACC}` },
                    { bottom: 10, right: 10, borderBottom: `2px solid ${ACC}`, borderRight: `2px solid ${ACC}` },
                  ].map((pos, i) => (
                    <div key={i} style={{ position: 'absolute', height: 24, width: 24, borderRadius: 2, opacity: 0.9, ...pos }} />
                  ))}
                  {!nodeFound && (
                    <div style={{ position: 'absolute', left: 16, right: 16, height: 2, background: `linear-gradient(90deg, transparent, ${ACC2}, transparent)`, boxShadow: `0 0 14px ${ACC}`, animation: 'zob-scan 2.6s ease-in-out infinite' }} />
                  )}
                  <AnimatePresence>
                    {nodeFound && (
                      <motion.div initial={{ opacity: 0, scale: 0.7 }} animate={{ opacity: 1, scale: 1 }}
                        style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(3,1,0,0.6)' }}>
                        <div style={{ display: 'flex', height: 58, width: 58, alignItems: 'center', justifyContent: 'center', borderRadius: 12, background: ACC, boxShadow: `0 0 40px ${r(0.6)}` }}>
                          <Check size={28} color="#180400" strokeWidth={3} />
                        </div>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontFamily: FM, fontSize: 9.5, letterSpacing: '0.12em', color: nodeFound ? GRN : w(0.4) }}>
                  {nodeFound ? <><Cpu size={12} /> NODE FOUND — OPTIMUS · KITCHEN</> : <><ScanLine size={12} /> SCANNING FOR NODES…</>}
                </div>
                {!nodeFound && <button style={quietBtn} onClick={skipNodes}>SKIP — NO NODES YET</button>}
              </StepWrap>
            )}

            {step === 'callsign' && (
              <StepWrap key="callsign">
                <input
                  value={callsign}
                  onChange={(e) => setCallsign(e.target.value.toUpperCase())}
                  maxLength={14}
                  style={{ width: '100%', height: 54, borderRadius: 10, background: w(0.04), border: `1px solid ${r(0.35)}`, outline: 'none', textAlign: 'center', fontFamily: FD, fontSize: 16, fontWeight: 700, letterSpacing: '0.3em', color: '#f5ede8', marginBottom: 10 }}
                />
                <button
                  style={{ ...primaryBtn, opacity: callsign.trim() ? 1 : 0.35, pointerEvents: callsign.trim() ? 'auto' : 'none' }}
                  onClick={() => setStep('done')}
                >
                  CONFIRM CALLSIGN <ArrowRight size={14} />
                </button>
              </StepWrap>
            )}

            {step === 'done' && (
              <StepWrap key="done">
                <div style={{ marginBottom: 14, textAlign: 'center' }}>
                  <span style={{ fontFamily: FD, fontSize: 9, fontWeight: 700, letterSpacing: '0.3em', color: GRN, border: `1px solid ${GRN}55`, background: `${GRN}12`, borderRadius: 4, padding: '5px 10px 4px 13px' }}>
                    ALL SYSTEMS NOMINAL
                  </span>
                  <div style={{ marginTop: 10, fontFamily: FM, fontSize: 9, letterSpacing: '0.12em', color: w(0.4) }}>
                    zeus-core · {routeMode === 'byok' ? 'byok routes' : '11 routes · managed'} · {solo ? 'solo' : '1 node enrolled'} · operator {callsign.toLowerCase()}
                  </div>
                </div>
                <button style={primaryBtn}>ENTER CONSOLE <ArrowRight size={14} /></button>
                <button style={quietBtn}>{solo ? 'ENROLL NODES LATER IN NODES TAB' : 'ENROLL ANOTHER NODE'}</button>
              </StepWrap>
            )}

          </AnimatePresence>

          <div style={{ marginTop: 14, textAlign: 'center', fontFamily: FM, fontSize: 8, letterSpacing: '0.16em', color: w(0.2) }}>ZEUS · NOVAXAI</div>
        </div>
      </div>
    </div>
  )
}

function StepWrap({ children }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 18 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -12 }}
      transition={{ duration: 0.45, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  )
}
