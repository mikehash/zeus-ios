# Phase 2 walk — ZEUS-tab agent surface

Base: `9e06d1a` (`feat/voice-level-seam`, parent `9a14940` = main).
Read-only walk. No code cut in this commit.

Dispatch (Zeus100, prototype `zeus-mobile-app1.jsx` is SoT, 3 tabs confirmed by
merakizzz): ZEUS tab = orb(level) + badge + ROUTE pill + COMMS voice cycle +
BROADCAST/PING + APPROVALS.

## 1. What the ZEUS tab already has

`HomeView.swift` (510 lines) body @ `:58-70`:

```
identity          ZEUS wordmark · OPERATOR · <callsign> · commission summary
agent             DeviceOrb(mode:level:) 250pt            :137
LinkCard          link.state + retry                      :63
statusGrid        AGENT · LINK · (+2) StatCells           :200
alertsRow         push.state badge + detail line          :225
ApprovalsSection  store: approvals                        :66
resume            restore-into-session
activityFeed      session.activity
```

So **APPROVALS is already shipped** (`ApprovalsSection(store:now:)`) and the
**badge is already shipped** — but deliberately *not* under the orb. The reason
is recorded at `HomeView:128-136` and pinned by `AccessibilityTests:28-40`: the
orb carries `DeviceOrb.Mode` (3 energies), the badge carries `AgentState`
(4 phases), `orbMode` folds `.listening`/`.responding` into `.speaking`. The
`AGENT` StatCell is this screen's badge. Moving it under the orb duplicates the
string; adding a second one renders the same phase twice and still leaves it
unrecoverable from the picture.

**Lean: keep the badge where it is.** The prototype's badge-under-orb is a
layout choice; the app's placement is an accessibility ruling with a leg behind
it. Re-siting needs that leg rewritten, not ignored.

## 2. ROUTE pill — real data exists, HomeView cannot see it

```
grep -cE 'routes|Route' Sources/ZeusApp/HomeView.swift   = 0     (NEG)
grep -ci  'session'     Sources/ZeusApp/HomeView.swift   = 24    (POS ctl)
RootView:104   @StateObject private var routes: RouteCatalogStore
RootView:540   NodesView(routes: routes, …)      ← sole consumer
NodesView:349  value: routes.selected?.name ?? "TAP TO SELECT"
Route.swift:365  func select(_ route: Route) -> String   (returns the toast)
```

`RouteCatalogStore` is live, fetched over HTTP (`HTTPRouteCatalogFetcher`),
with a real `RouteCatalogState` including `emptyReason`. The ROUTE pill is a
**second reader of an existing store**, not new data: pass `routes` into
`HomeView`, render `routes.selected?.name`, tap opens the same selection surface
`NodesView:263-278` already draws.

No literal provider list. The prototype's `ROUTES` array (8 hardcoded entries
with invented `P50 180MS` latencies) must NOT be transcribed — that is the
`t-12min` defect wearing a catalog. The app's real catalog is the source.

## 3. COMMS — the wiring is a new read, not a replacement

```
RootView:61    @StateObject private var voice = VoiceInput()   ← sole owner
RootView:490   HomeView(link:session:push:onOpenSession:onOpenGatewayEditor:
                        approvals:resolution:)                ← no voice param
RootView:528   voiceState: voice.state,  onVoice: voice.toggle ← SessionView only
Voice.swift:269  @Published private(set) var level: Double     ← 9e06d1a
```

COMMS on the ZEUS tab = pass `voiceState` / `onVoice` / `voice.level` the same
way `SessionView` already receives the first two. `SessionView:463-466` shows the
button shape (`accentButton(symbol:label:enabled:action:)` gated on
`voiceState.isActionable`), and `voiceSymbol`/`voiceLabel` at `:488`/`:500` are
the per-state strings.

### The orb's `level` on this screen

`HomeView.orbLevel(for:)` at `:172` returns `0.7`/`0.2` and its own doc at
`:156-158` says *"THIS IS NOT AN AUDIO AMPLITUDE AND MUST NOT BE READ AS ONE …
nothing on this screen meters anything."* That was **true and correct** while
the screen had no mic. Wiring COMMS here makes the screen meter — so the
constant is replaced by `voice.level` **only in the states where the mic is
actually running**, and stays a derived constant otherwise. A live meter number
shown while the tap is not installed is the same fabrication with the sign
flipped.

### `Commissioning:534` must NOT be touched

```
grep -c 'VoiceInput|SFSpeech|AVAudioEngine' Commissioning.swift = 0   (NEG)
grep -c 'Narrator' Commissioning.swift                          = 1   (POS)
Commissioning:534  DeviceOrb(mode: orbMode, level: narrator.isNarrating ? 0.7 : 0.2)
```

Commissioning has **no microphone**. Its orb sits over `Narrator` — text-to-
speech, output not input. `narrator.isNarrating ? 0.7 : 0.2` is an honest
two-valued constant over a real reading. Feeding a mic RMS into it would be a
fabrication in the opposite direction: metering audio the screen is not
capturing. The dispatch line "kill the `Commissioning:534` constant" is
**declined with reason**; the constant that needed killing is the one on the
screens that listen, and those slots did not exist yet.

## 4. BROADCAST / PING — 🔴 no backing anywhere. BLOCKER.

```
grep -rIil broadcast Sources/ZeusApp Sources/ZeusCoreFFI = 0   (NEG)
grep -rIil chime     "                                "  = 0   (NEG)
grep -rIil session   "                                "  = 31  (POS ctl)
endpoints the app knows:  /v1/sessions · /v1/memory/files
                          /v1/memory/remember · /v1/memory/search
ZeusCore FFI methods:     hasProvider indexSize listModels messages remember
                          search send sessions setProvider
"ping" hits in Sources are 3 × the word "mapping"/"stepping" + NodesView doc
prose. Zero implementations.
```

The prototype's handlers are:

```jsx
onClick={() => nodeOnline ? showToast('BROADCAST SENT — KITCHEN NODE')
                          : showToast('NODE UNREACHABLE — QUEUED FOR NEXT LINK')}
onClick={() => nodeOnline ? showToast('PING — KITCHEN NODE CHIMED') : …}
```

Both are literal toasts in a demo. There is **no transport, no endpoint, and no
FFI method** that could send either. Shipping them as drawn means two buttons
that assert a node was reached and made a sound when nothing left the phone —
the costume defect at its most visible, on the cold-start screen, above a real
APPROVALS queue that *is* honest. `NODE UNREACHABLE — QUEUED FOR NEXT LINK`
additionally claims a queue that does not exist.

**Three options, lean stated:**

- **(a) Ship the buttons disabled** with a real reason string (the shape
  `NodesView` already uses via `Row(disabled:)` and `voiceState.unavailable`).
  Honest, visible, matches the prototype's geometry, costs one commit.
  **← lean.**
- **(b) Omit them** until a transport lands. Cleanest, but diverges from a
  prototype merakizzz confirmed 100%, and the divergence is invisible to him.
- **(c) Build the transport.** `POST /v1/node/broadcast` + `/v1/node/ping` do
  not exist gateway-side; this is a bridge + gateway cut, not Swift-only, and
  breaks the "no bridge rebuild, no pin move" constraint on every phase.

## 5. Cut order for Phase 2 (pending the (a)/(b)/(c) ruling)

1. `HomeView` gains `routes`, `voiceState`, `onVoice`, `level` params;
   `RootView:490` supplies them from stores it already owns. No new state.
2. ROUTE pill reading `routes.selected?.name` with the catalog's own
   `emptyReason` on the empty arm — never a literal provider list.
3. COMMS button reusing `voiceState.isActionable` / `voiceSymbol` / `voiceLabel`.
4. `orbLevel` becomes arm-selected: live `voice.level` while listening,
   derived constant otherwise, with the doc comment rewritten to that truth.
5. BROADCAST / PING per ruling.

### Mutations required (each must red with the build ALIVE)

- ROUTE pill fed a literal instead of `routes.selected` → the reader leg reds.
- `orbLevel` pinned to the old constant while listening → the live-meter leg reds.
- COMMS action swapped off `onVoice` → the wiring leg reds.
- Disabled-arm reason replaced by an active-looking toast → the honesty leg reds.

Every view-side leg is a **source slice**, not a property assertion: `HomeView`
has no in-process observable, and a leg asserting a *type's* property witnesses
nothing about the *view* reading it. That class has now arrived four times
(S3a `SessionRow`, S3b private method, S5 `icon: "doc"`, Phase 1 tap wiring).

## 6. Phase 1 status

`9e06d1a` is on origin (`feat/voice-level-seam`, parent `9a14940`, 1 commit,
`Voice.swift` +96 / `VoiceTests.swift` +152, `rust/` diff 0, no pin move).
599 tests / 1 skipped / 0 failures, guards 6/6, three build-alive mutations.
Awaiting gate.
