# iOS wiring census — every control and status surface, classified

**Pin:** iOS `main = 80f3888` (TestFlight 188). Read-only walk; no code changed.

**Classes.** WIRED — a real production producer→consumer, named by call path.
HONEST-DISABLED — dead by design, with a truthful on-screen reason.
DEAD — looks live, does nothing on tap. PLACEHOLDER — static or mock.

**Rule applied throughout:** "wired" means *has a production caller*, not
*is defined*. Every absence claim below carries a POS control in the same
invocation, because a grep that silently didn't run returns a clean zero.

---

## 🔴 The headline: one DEAD control, and it is worse than a no-op

**`LinkCard`'s retry button (`HomeView:673`) corrupts the pill on the LOCAL
arm.** It is the only DEAD control in the app, and it is not merely inert.

```
HomeView:95   LinkCard(state: link.state, onRetry: { Task { await link.probeOnce() } })
HomeView:673  Button(action: onRetry) { … }          ← rendered UNCONDITIONALLY
LinkMonitor:416  func probeOnce() async {
LinkMonitor:417    guard case .resolved(let endpoint) = config else {
LinkMonitor:418      state = .unconfigured                              ← 🔴
```

On `.local` — which is **every phone in the field today**, because the fork's
LOCAL arm resolves there — the pill is `.embedded`, rendering
`LOCAL · ON THIS PHONE`. `LinkMonitor.state(for:)` at `:308` calls `.embedded`
a **terminal** state in its own comment: "the pill should never move off it."

Tap the retry arrow and it does. `probeOnce`'s guard folds `.local`,
`.absent` and `.malformed` into one `else` and writes `.unconfigured`, so the
card flips to **`NO GATEWAY · SET ZEUS_GATEWAY_URL`** — an instruction to fix
a thing that is not broken, on a device that is working correctly. Nothing
ever puts it back: `start()` guards on `.resolved`, so no poll loop is open on
this arm to re-derive the label. The corruption survives until relaunch.

Blast radius is four surfaces, because they all read the one monitor:

```
HomeView:95    LinkCard status + subtitle
HomeView:451   LINK status tile   → NO GATEWAY
HomeView:506   LATENCY tile       → —
RootView:531   SESSION header statusLine
                                     NEG ctl `zzz.state` = 0
```

**Why no test caught it.** `probeOnce` has four test callers
(`LinkMonitorTests:108/118/129/208`) and **not one of them is on the `.local`
arm** — the grep for `local|embedded` in their vicinity returns empty against
a live file. The guard was written for `.absent`, where `.unconfigured` is the
right answer, and `.local` was swept into the same `else` by shape.

**Repair.** Two legs. `probeOnce` must return without writing on `.local`
(a core in-process has nothing to probe, so the honest act is *no act*), and
the button must not render on an arm where it cannot do anything — an enabled
control that is correct to ignore is the shape this codebase already retired
at BROADCAST/PING. Cheapest correct form: `LinkCard` takes the retry closure
as `(() -> Void)?` and `HomeView` passes `nil` unless `state.isProbeable`.

---

## (a) ROUTE: "LOCAL CORE ENUMERATES NO PROVIDERS YET" — why nothing enumerates

**Verdict: HONEST-DISABLED, correctly, and the string is true.** It is not a
reachability failure and not a missing arm flow. It is a missing HTTP surface.

```
Route.swift:335  case .local: return .unconfigured("local core enumerates no providers yet")
```

The route catalogue is `GET {base}/v1/providers` — an HTTP endpoint. The
embedded core is in-process and **has no HTTP surface at all**, so there is no
list to fetch; `load()` guards on `.resolved` and would spin forever otherwise.
Ollama on the LAN is irrelevant here: the catalogue never tries to reach
anything.

🔴 **But the string under-reports what the phone can do, and that is the
actionable finding.** The bridge *does* export enumeration — it just isn't the
same verb:

```
list_providers()        lib.rs:1318  → Provider::ALL, static, no network
credential_shape(id)    lib.rs:1335
list_models(id,key,url) lib.rs:340   → live fetch per provider
```

`listProviders` is in the generated bindings (count 1; POS ctl `setProvider`
= 2, NEG ctl = 0) and **has exactly one production caller** —
`Commissioning:1081`, the ROUTES step of onboarding. So the phone enumerates
providers *once*, during commissioning, and then the ZEUS tab's ROUTE pill
says nothing enumerates. Both statements are true of different verbs, and the
operator reads one sentence.

The catalogue is a **remote-gateway concept** rendered on a local-core device.
That is the real gap, and it is a wiring job, not a bug.

## (a′) TURNS 0 — correct, and it is the symptom, not the cause

```
HomeView:508  messages.filter { $0.role == .agent && !$0.streaming }.count
```

WIRED and honest: it counts completed agent messages in the live
`SessionEngine`, seeded `[]` at `RootView:331`. It reads 0 because **no turn
has ever completed on this device**, and the transcript is not hydrated from
disk at launch (`Session.swift:280` — `messages = seed`, and the one
production call site passes `[]`). Sessions written by the core are reachable
only through the history sheet.

**Why no turn completes.** The arm chain is fully built and correct:

```
RootView:252   CoreArming.arm(commission:core:providerKey:baseURL:)   ← sole prod caller
ProviderArming:129  guard let core           else "core failed to initialise"
ProviderArming:130  guard commission.provider else GatewayConfig.noProviderMessage
ProviderArming:136  guard let model          else "NO MODEL — <LABEL> LISTED NONE"
SessionCapabilities:247  core.setProvider(id:model:key:baseUrl:)      ← the one call
```

Every one of those inputs comes from **one screen, once**: ROUTES inside
commissioning. `recordRoutesChoice` has two production callers
(`Commissioning:1064` and `RootView:238`, the latter `#if DEBUG`-gated by
`LaunchArgs.seededProvider`, unconditionally `nil` in release). So in a
shipped build there is **exactly one way to ever set a provider, and it is
behind a flow that only runs once, before first launch completes.**

An operator who reached `done` without a provider gets the correct sentence
("No provider on your record") and a `SET A PROVIDER` button at
`Commissioning:832` — *inside commissioning*. After `onComplete` fires at
`:812`, that screen is gone for the life of the install. `decommission()`
(`ZeusApp:60`) would bring it back and its doc cites "NODES → REVOKE ACCESS",
but the subject census is decisive: **production callers 0** (POS ctl
`onToast(` = 6, NEG ctl = 0). `NodesView:35` admits the row was removed.

🔴 **So: if commissioning finished without a provider, the app has no
reachable path to add one, ever.** ROUTES → NODES → gateway row opens the
*gateway editor* (a URL + token), not the provider picker. That is the
top-priority wiring arc and it is why the phone cannot run a turn.

## (b) BROADCAST / PING — HONEST-DISABLED, proven, nothing to fix

```
HomeView:245  controlButton(symbol: "megaphone",  enabled: false …)
HomeView:250  controlButton(symbol: "mappin.and.ellipse", enabled: false …)
HomeView:340  "BROADCAST · PING — NO NODE TRANSPORT ON THIS BUILD"
```

Not DEAD — `.disabled(!enabled)` at `:363`, `enabled: false` at both sites,
and the on-screen reason is rendered. The absence is proven by a POS/NEG
census recorded in the file's own doc at `:305-312`: node verbs
(`broadcast/chime/pingNode/wakeNode/restartNode`) = 0 in app and 0 in FFI,
against `session` = 361/49 live and `zzzNoVerb` = 0 dead.

Deliberately **not** conditioned on `link.isLinked` — a linked gateway still
has no node verb, so gating on link would promise the control works once
connected. To become real it needs a node transport in the core (FFI verbs +
a node registry), which is a zeus107-side subsystem, not an app wiring job.

---

## ZEUS tab

| Surface | Class | Call path / reason |
|---|---|---|
| COMMS | **WIRED** | `HomeView:240` → `onVoice` → `RootView:520` → `voice.toggle` → `Voice:291` (real `SFSpeechRecognizer` + tap) |
| BROADCAST | **HONEST-DISABLED** | `enabled: false`, reason on screen (above) |
| PING | **HONEST-DISABLED** | same |
| Orb | **WIRED** | `HomeView:380` — `micLevel` is real RMS from `Voice:274` while `.listening`; two-valued constant otherwise, documented |
| ROUTE pill | **WIRED (tap)** / **HONEST-DISABLED (value)** | tap → `RootView:522` → `tab = .nodes`; value is `routes.state.emptyReason`, honest on `.local` |
| LINK retry ↻ | 🔴 **DEAD (corrupting)** | `probeOnce` writes `.unconfigured` on `.local` — see headline |
| AGENT tile | **WIRED** | `HomeView:447` → `ReadinessBadge.forState(session.state, disarmReason:)` — engine phase composed with arm readiness |
| LINK tile | **WIRED** | `HomeView:451` → opens gateway editor; value from `LinkMonitor` |
| TURNS tile | **WIRED** | `HomeView:508` over live `session.messages` |
| LATENCY tile | **WIRED** | `HomeView:509` — `\(ms)MS` only from `.linked`, `—` otherwise; never remembered |
| ALERTS ENABLE | **WIRED** | `HomeView:481` → `push.request()` → `PushRegistrar:224` → real `UNUserNotificationCenter` |
| ALERTS badge | **WIRED** | four honest arms; `.authorizedAwaitingToken` renders `allowed · no device token yet` rather than ON |
| APPROVALS | **WIRED (remote)** / **HONEST-DISABLED (local)** | `Approvals:534` → `store.resolve` → real POST `:327`; `.local` → `"local core has no agent loop yet"` at `:420` |
| RESUME bar | **WIRED** | `HomeView:519` → `RootView:505` → `tab = .session`; label derived from transcript state |
| Activity feed | **WIRED** | `Session:348` — every non-token frame recorded; empty because no turn has run |

⚠️ **Not a control, but a dead end:** the APNs device token is never
transmitted anywhere. Subject census — `tokenSuffix`/`registered(` outside
`PushRegistrar.swift` = 0, no `/v1/push` or device-registration POST (POS ctl:
`method: "POST"` = 2, both in `Approvals`). The badge honestly says a token
exists; nothing can ever send a notification *to* it. Registration is a
gateway-side arc.

## SESSION tab

| Surface | Class | Call path / reason |
|---|---|---|
| ATTACH 📎 | **WIRED** | `SessionView:658` → picker → coherence guard (`80f3888`) → staged into confined workspace; `attachEnabled = true` unconditioned by design (staging works offline) |
| COMMS (hero) | **WIRED** | `RootView:554` → `voice.toggle`; transcript lands in composer, no tab switch |
| Keyboard | **WIRED** | `SessionView:669` → local `showKeyboard.toggle()` |
| Transcript toggle | **WIRED** | `SessionView:673` → `showLog.toggle()` |
| Composer field | **WIRED** | `SessionView:769`, `.onSubmit(send)` at `:791` |
| SEND ↑ | **WIRED, gated** | `:810` → `send()` → `RootView:539` → `SessionEngine.send` → `makeTransport` → `EmbeddedTransport` → `core.send`. Gated by `canSend` (`:224`) on `disarmReason`, so it is correctly disarmed today |
| History | **WIRED** | `SessionView:511` → `RootView:556` → `HistorySheet` → `core.sessions()` / `core.messages(id)` — real reads |
| REMEMBER | **WIRED** | `RootView:727` → `core.remember`, arm-selected outcome string |

## NODES tab

| Surface | Class | Call path / reason |
|---|---|---|
| MOBILE NODE card | **WIRED** | `CoreProvenance.nodeSubtitle()`, badge from config arm |
| Mnemosyne row | **WIRED** | `NodesView:340` → re-reads `indexSize`, reports `READING` in flight, abstains with no core |
| Route row | **WIRED (tap)** | `:348` → opens route sheet; value `routes.selected?.name ?? "TAP TO SELECT"` |
| Route sheet rows | **WIRED** | `:267` → `routes.select(rt)` → device-local preference + scoped toast. Zero rows on `.local`, with `emptyReason` |
| Gateway row | **WIRED** | `:335` → `onOpenGatewayEditor` → real editor, persists URL + token |
| Memory search | **WIRED** | `:441` `.onSubmit(runFind)` → `core.search`, generation-guarded, throw is load-bearing (`[]` ≠ "couldn't ask") |
| **ENROLL NODE** | 🟠 **PLACEHOLDER** | `:613` → `onToast("NODE ENROLLMENT — SCAN THE NEW DEVICE")` only. Not corrupting, but the toast describes an act that never begins — the same class as the retired `MNEMOSYNE CONSISTENT` fabrication. Needs the same node transport as BROADCAST/PING |

## Provider enumeration / arming (cross-cutting)

| Surface | Class | Notes |
|---|---|---|
| Provider picker | **WIRED** | `Commissioning:1081` → `ProviderCatalog.current.rows()` → FFI `listProviders` |
| Model poll | **WIRED** | `:1237` → `core.listModels` live, debounced on key (`:1269`) and base-URL (`:1153`) change |
| Key field → Keychain | **WIRED** | `:1072` → `keys.setProviderKey` after the record write |
| VALIDATE + CONTINUE | **WIRED, gated** | `:1057`, `.disabled(!routesCTAEnabled(…))` — both halves required, `.url` needs an endpoint |
| Core arming | **WIRED** | `RootView:252` → `CoreArming.arm` → the one `setProvider` |
| 🔴 **Re-entry to ROUTES after commissioning** | **ABSENT** | no production caller — see (a′) |

⚠️ **Aperture.** This is a source census at `80f3888`, not a device run. It
proves what has a production caller and what a control writes; it does not
prove behaviour under a real provider, and every "WIRED" on the send path is
wired-but-disarmed until a provider exists.

---

## Step 2 — wiring plan, priority order

**#1 — A reachable ROUTES screen after commissioning.** *Unblocks the real
turn.* Today the only `recordRoutesChoice` production caller is inside a flow
that runs once. Lift the ROUTES step into a sheet presentable from
NODES → Route (which already exists and today only offers gateway-fetched
rows, of which there are zero on `.local`), reusing `routesCTAEnabled`,
`ProviderCatalog.current.rows()`, `ModelPoll`, and the existing key write.
On commit, re-run `CoreArming.arm` so the pill and AGENT tile move without a
relaunch. Guards: `recordRoutesChoice` production callers ≥ 2 with one
reachable outside `#if DEBUG`; a leg asserting arm re-runs after the sheet
commits; the existing CTA-gate legs unchanged.

**#2 — The DEAD retry button.** *Smallest cut, active harm.* `probeOnce`
returns without writing on `.local`; the button renders only where it can act.
Mutations: delete the new guard → a `.local` leg reds; make the closure
non-optional → the census reds.

**#3 — Local-arm route catalogue.** Replace the ROUTE pill's
"enumerates no providers yet" with the core's own answer once #1 exists:
`listProviders` + the armed selection. Turns an honest absence into a fact.

**#4 — ENROLL NODE.** Either terminal-disable it with the BROADCAST/PING
reason (cheap, honest, today) or wait for the node transport. I lean
disable-now: a toast that narrates a scan nobody started is the exact shape
this codebase keeps retiring.

**#5 — Transcript hydration at launch.** TURNS and the activity feed start
empty on every cold start although the core has the sessions on disk. Seed
`SessionEngine` from the newest session rather than `[]`.

**#6 — APNs device-token registration.** Gateway-side; the app half is done.
