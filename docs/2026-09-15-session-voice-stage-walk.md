# Walk — prototype `zeus-mobile-app1.jsx` vs app @ `9e06d1a9`

Dated 2026-09-15. Read before cutting. Source of truth for the delta is the
diff between the two prototypes on disk, not recall:

    3920ce62…_zeus-mobile-app.jsx   (2026-08-31, the one the app was built from)
    7d7d1145…_zeus-mobile-app1.jsx  (2026-09-16, "the changes I requested")

    diff  -> 245 changed lines, THREE hunks: @@ -3,7 @@  @@ -657,9 @@  @@ -852,74 @@

## The headline: there is NO voice tab in this prototype

    grep -cE "^ *\{ id: '(zeus|session|nodes|voice)', label:"   -> 3
    grep -c  "id: 'voice'"                                     -> 0   (NEG)
    :398  const [tab, setTab] = useState('zeus')  // zeus | session | nodes

The verbal ask was "one more tab for voice, with the orb". The prototype does
something different and, on reading it, better: **SESSION becomes voice-first.**
Tab count stays 3, so `Tab.allCases` stays 3 and `DeepLinkTests:96`'s floor
does NOT move.

## What actually changed (the three hunks)

1. **imports** +6 glyphs: Paperclip, Keyboard, Camera, Image, FileText, List.

2. **`SessionTab` call site** (`RootView` equivalent, :658):
   - `onVoice={() => { setTab('zeus'); later(runVoiceQuery, 350) }}`
     -> `onVoice={runVoiceQuery}`  — **voice no longer bounces to the ZEUS tab;
     it runs in place.** This is the line that makes SESSION the voice screen.
   - new props `agentState`, `partial` — the stage needs live state.
   - new prop `onAttach(name)`.

3. **`SessionTab` body — full rewrite.** Default body is a **voice stage**:
   - `:913  <DeviceOrb mode={om} …/>` 200x200, centred, orb IS the screen.
   - `agentState==='ambient'` -> "TAP COMMS TO TRANSMIT"
   - `'listening'` -> live `partial` + blinking caret
   - last-two bubbles under the orb; **full transcript is secondary**, behind a
     `List` toggle in the header (`showLog`).
   - **text input is collapsed** behind a Keyboard toggle (`showText`), was
     always-visible before.
   - three-button row: Paperclip (attach sheet: camera/photos/files) ·
     big Mic (comms) · Keyboard.
   - attachment chip above the composer, dismissible.

## Substrate consequence for the app

- `Sources/ZeusApp/SessionView.swift` is 591 lines and already has: transcript
  `ScrollView` (:345), `composer` (:429), `voiceSymbol`/`voiceLabel` (:488/:500),
  `voiceState` with `.unavailable` refusing to arm (:460-465), `onRemember`.
  The rewrite is a **re-layout of existing parts**, not new capability.
- `Tab` enum unchanged -> no `DeepLinkTests:96` move, no new routing.
- `SessionView` orb: `OrbGlyph` exists at :573 (`tuning: .glyph`). The stage
  needs the full renderer at stage size, not the glyph.

## The defect the prototype carries and the app must NOT copy

    :913  <DeviceOrb mode={om} style=…/>        <- NO level prop -> level = 0
    :430  setLevel(Math.random() * 0.7 + 0.15)  <- the ZEUS tab's meter is FAKE

The prototype's voice stage orb does not meter at all, and the one orb that
does is fed `Math.random()`. Copying either would put a hardcoded/fake meter on
the most visible surface in the app. `VoiceMeter.level(samples)` landed at
`9e06d1a9` reads the real tap buffer — **the stage orb takes that**, and the
leg is a source slice (the view has no in-process observable; a property leg on
the type witnesses nothing about the view reading it — the S5 `icon:"doc"` class).

## Open ruling before cutting

Auto-send. `RootView:410` states voice NEVER AUTO-SENDS and
`VoiceTranscript.accepted` refuses on purpose. A voice-first SESSION stage with
a collapsed keyboard still requires a tap to send under that invariant. The
prototype does not settle it — its `runVoiceQuery` is a scripted demo that
appends both turns itself. Needs merakizzz's call.
