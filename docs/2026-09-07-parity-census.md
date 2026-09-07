# Prototype-parity gap census — what "100%" means

**SoT:** `/Users/mike/mobile-apps/prototypes/zeus/` — `ZeusApp.jsx` (925) + `ZeusCommissioning.jsx` (658).
**NOT a git repo** (`git rev-parse` → `fatal: not a git repository`), so the SoT has no sha; it is a
working directory dated `Aug 31 15:24`. Every prototype coordinate below is a line number in those
two files as they stand on this box today.

**App under census:** `~/zeus-ios` @ `08181b1`, porcelain 0, 200 test functions.
`git ls-files | grep -icE '\.(jsx|tsx)$'` in `zeus-ios` = **0** (POS ctl `.swift` = 34) — the prototype
is not vendored into the app repo, so no leg on this branch can compare them. This table is a
**read**, not a measurement: it is two humans-worth of file reading, and its needles are stated per
row so any row can be refuted.

Ordered as merakizzz will touch it: **onboarding → session loop → nodes**.

---

## A. ONBOARDING — `ZeusCommissioning.jsx` → `Commissioning.swift`

| # | Prototype affordance | Proto coord | State | Needle / note |
|---|---|---|---|---|
| A1 | 6-step machine `welcome→auth→routes→nodes→callsign→done` | `:303` | **PRESENT** | `enum CommissioningStep: String, CaseIterable { case welcome, auth, routes, nodes, callsign, done }` — `Commissioning.swift:20-21`, exhaustive switch at `:211-317` |
| A2 | Step progress dots | `:456` | **PRESENT** | `ForEach(Array(CommissioningStep.allCases.enumerated())…)` `:142`; index at `:181` |
| A3 | Orb, size + mode per step | `:392-393` | **PARTIAL** | `DeviceOrb` ×3 in file, `:110` `mode: orbMode, level: narrator.isNarrating ? 0.7 : 0.2`. Proto also varies **size** (290 on welcome/done, 185 elsewhere) — size variation not read at any site |
| A4 | Voice narration per step | `:305` `NARRATION` | **PRESENT** | 18 `narrator` refs in `Commissioning.swift` |
| A5 | `INITIALIZE` | `:498` | **PRESENT** | `PrimaryButton("INITIALIZE", glyph: "arrow.right") { step = .auth }` |
| A6 | `CONTINUE WITH PASSKEY` / `USE NOVAXAI ID` | `:502` block | **PRESENT (cosmetic)** | Both buttons exist; both call `doAuth`. **No real auth** either side — the prototype's is a fake too, so this is parity, not a gap. Flagged because "PASSKEY" reads as a security claim |
| A7 | `OPERATOR VERIFIED · MIGUEL` | `:514` | **PRESENT** | literal, 1 hit |
| A8 | Route choice `MANAGED` / `BYOK` | `:524-525` | **PRESENT** | `enum Route: String, Codable { case managed, byok }` `:67`, persisted via `CommissionStore` |
| A9 | `SCAN NODE` / `SKIP — RUN SOLO` | `:565` block | **PRESENT** | both literals in `Commissioning.swift`; scanning state renders `SCANNING…` |
| A10 | Callsign entry | `:606` | **PRESENT** | `TextField` bound to `commission.callsign` |
| A11 | `ENTER CONSOLE` | `:623` | **PRESENT** | 1 hit |
| A12 | **Back navigation** (`back()`, `:389`) | `:389` | **ABSENT** | `grep -ci 'back\b' Commissioning.swift` = 0. The prototype lets you step backwards; the app is forward-only. **Onboarding's only true absence** |

**Onboarding verdict: 10 present, 1 partial (orb size), 1 absent (back nav).**

---

## B. SESSION LOOP — `ZeusApp.jsx` SessionTab `:855-925` + ZEUS tab `:528-660` → `SessionView.swift` / `HomeView.swift`

| # | Prototype affordance | Proto coord | State | Needle / note |
|---|---|---|---|---|
| B1 | Three tabs ZEUS/SESSION/NODES | `:835-837` | **PRESENT** | `enum Tab { case zeus, session, nodes }` `RootView:10-12`, docstring cites the proto lines |
| B2 | Transcript, user/agent bubbles | `:881-889` | **PRESENT** | `SessionView:157` "Transcript (:879-898)" |
| B3 | Token-by-token streaming | `:461-469` | **PRESENT, and REAL** | proto fakes it with `setTimeout` per word; app has a live `SSEDecoder` (363 lines, 455 lines of tests). **App exceeds SoT here** |
| B4 | Composer + send | `:900-914` | **PRESENT** | `TextField` `:223`, `accentButton(symbol:"arrow.up", label:"Send")` `:253` |
| B5 | Mic / Comms button | `:914` | **PARTIAL** | button present `SessionView:251`; whether it routes to real STT is unverified by this walk |
| B6 | 4 agent states + badge | `:333` `BADGES` | **PRESENT** | `enum AgentState { ambient, listening, thinking, responding }` with 4 distinct `badgeText` + 4 distinct colours, `AgentState.swift:21-66` |
| B7 | Status line per state | `:477-481` | **PRESENT** | same 4-way switch |
| B8 | **Orb on the ZEUS tab** | `:544` | **ABSENT** | `grep -c DeviceOrb HomeView.swift` = **0**. The orb is the app's centrepiece in the prototype's home screen; in the app it lives only in `Commissioning:110` and `SessionView:332` (glyph tuning). **Biggest single visual gap** |
| B9 | **Big mic → voice query on ZEUS tab** | `:578-587` | **ABSENT** | `grep -ci mic HomeView.swift` = 0; `runVoiceQuery` 0 hits repo-wide |
| B10 | **Proposal cards + APPROVE/DENY** | `:313-321`, `:618-640` | **ABSENT** | `proposal` = **0 hits repo-wide**. Prometheus proposals are an entire feature, absent |
| B11 | **LINK toggle HOME-LAN ↔ REMOTE** | `:533` `switchLink` | **ABSENT as a control** | `switchLink` 0 hits. Link *state* is present and **better** — `LinkMonitor` (311 lines) derives it from a real gateway probe rather than a toggle. The missing thing is the demo switch, which should probably stay missing |
| B12 | `BROADCAST` button | `:590` | **ABSENT** | `broadcast` 0 hits repo-wide |
| B13 | `PING` button (home) | `:598` | **PARTIAL** | absent on home; present in NODES as `NodeRow(icon:"mappin.and.ellipse", label:"Ping node")` `NodesView:177` |
| B14 | Toast, one at a time, 2800ms | `:433` | **PRESENT** | `RootView:51-98,207-211`, duration cited to the proto line |
| B15 | Route pill under the wordmark | `:566` | **PARTIAL** | route *name* renders (`routeName`, 2 hits); the pill-as-button that opens the sheet is not on home |
| B16 | Status grid AGENT/LINK/TURNS/LATENCY | — | **APP-ONLY** | `HomeView:106` — not in the prototype. App addition |
| B17 | ALERTS / push-permission row | — | **APP-ONLY** | `HomeView:120-137`, `PushRegistrar` 267 lines |
| B18 | Resume-session bar | — | **APP-ONLY** | `HomeView:174` |

**Session-loop verdict: 8 present, 3 partial, 4 absent, 3 app-only additions.**

---

## C. NODES — `ZeusApp.jsx :668-835` → `NodesView.swift`

| # | Prototype affordance | Proto coord | State | Needle / note |
|---|---|---|---|---|
| C1 | MOBILE NODE card + ACTIVE badge | `:678-682` | **PRESENT** | `NodesView:72` MARK cites `:671-686` |
| C2 | Mnemosyne row | `:685` | **PRESENT** | `NodeRow(icon:"cylinder.split.1x2", label:"Mnemosyne")` `:99` |
| C3 | Route row | `:686` | **PARTIAL** | row present `:103`; tapping toasts `"ROUTE SELECT — SHEET NOT PORTED"` `:105` |
| C4 | KITCHEN/ZEUS NODE card + LINKED/REMOTE badge | `:697-702` | **PRESENT** | `LinkMonitor.badgeText` returns exactly `LINKED`/`REMOTE` `:107-115` |
| C5 | Volume + brightness sliders | `:714-715` | **PRESENT** | `NodeSlider` ×2 `:166-167` |
| C6 | Mic hot/cold toggle | `:718` | **PRESENT** | `NodesView:206-217`, `voiceOn` 12 hits |
| C7 | Ping node | `:730` | **PRESENT** | `:177` |
| C8 | Restart | `:731` | **PRESENT** | `:181` |
| C9 | Revoke access | `:730` | **PARTIAL** | row present `:189`, `danger: true`; **confirm sheet not ported** — toasts `"REVOKE — CONFIRM SHEET NOT PORTED"` and deliberately does not act. Comment at `:185-188` states why |
| C10 | Sector row (`KITCHEN`) | `:729` | **ABSENT** | `sector` 0 hits repo-wide |
| C11 | ENROLL NODE | `:739` | **PRESENT** | `:250-256` |
| C12 | **ROUTE SELECT sheet** (11 routes, lock, toast) | `:322-331`, `:760-790` | **ABSENT** | `routeSheet` 0 hits. Only the toast stub at `:105` |
| C13 | **Revoke confirm sheet** | `:800-825` | **ABSENT** | `confirmRevoke` 0 hits |

**Nodes verdict: 8 present, 3 partial, 2 absent (both modal sheets).**

---

## What "100%" is, ordered

Nine items. Four of them are one shape: **the app has no modal-sheet layer.**

1. **B8 — orb on the ZEUS tab.** Highest visual impact, lowest risk: `DeviceOrb` already exists and is
   already used at two sites. Wiring is `AgentState.orbMode` (already written, `AgentState.swift:53-55`).
2. **B10 — proposal cards + approve/deny.** The largest genuinely-new feature. Needs a data source;
   the prototype's is a hardcoded array.
3. **C12 — ROUTE SELECT sheet.** 11 routes + lock + toast. First sheet; establishes the layer.
4. **C13 — revoke confirm sheet.** Second sheet, reuses the layer. Currently a stated non-action.
5. **B9 — big mic / voice query on home.** Depends on whether B5's mic is real.
6. **A12 — back navigation in onboarding.** One-line-ish; forward-only today.
7. **B12 — BROADCAST.** Toast-only in the prototype; cheapest row here.
8. **C10 — sector row.** Toast-only in the prototype.
9. **A3 — orb size varies by step.** Cosmetic.

**Deliberately NOT on the list:** B11's LINK toggle. The prototype toggles link state by hand; the app
derives it from a real gateway probe. Porting the toggle would be a regression dressed as parity.

## Aperture

- The prototype is not under version control and not in this repo — nothing on the branch can gate
  against it, and this table goes stale the moment either side moves.
- Every "ABSENT" is a symbol census over `Sources/` with a NEG control (`qqzz4417` → 0) and, where
  a positive control was available, a POS control (`NodeRow` → 6). A symbol census cannot see a
  feature implemented under a different name; the ones marked ABSENT were each also read for by
  eye in the plausible destination file.
- "PRESENT" means the affordance renders and its state is derivable. It does **not** mean visual
  fidelity was compared — no screenshot diff against the prototype exists, and this box cannot make
  one (the prototype is React, unrunnable here without a toolchain that isn't installed).
