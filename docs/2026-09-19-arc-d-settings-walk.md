# Arc D walk — the SETTINGS tab

Read-only. Substrate at `main 929db99`. No code touched.

Arc B's walk killed three of four reuse symbols before a line was written. This
one is cheaper — two of the three rows are already raises — but it carries a
hazard Arc B did not: **NodesView is a census SUBJECT, and this arc shrinks it.**

---

## 1. `Tab` — a fourth case is structurally safe, and already guarded

`RootView.swift:9-12`. Three cases, `String`-raw, `CaseIterable`.

    enum Tab: String, CaseIterable, Identifiable { case zeus, session, nodes }

Consumers, measured (`grep -n "switch tab\|Tab.allCases"`):

| site | shape | effect of a 4th case |
|---|---|---|
| `RootView:534` `switch tab` | **no `default:`** | fails to compile — correct |
| `RootView:19/29` `label`/`symbol` | no `default:` | fails to compile — correct |
| `RootView:861` `ForEach(Tab.allCases)` | data-driven | renders automatically |
| `DeepLink.swift:66` `Tab(rawValue:)` | data-driven | `zeus://settings` parses free |

The `@unknown default: break` in `RootView` belongs to the `scenePhase` switch,
not the tab switch — checked, not assumed.

🔴 **`DeepLinkTests:96 testEveryTabIsReachable` asserts `Tab.allCases.count == 3`
and then that every case has a working link.** A fourth tab reds it on a correct
tree. That is the leg working: the floor moves with the declaration and the loop
below it proves the new tab is actually reachable, not just counted. Floor goes
3 → 4 with the reason recorded at the leg.

## 2. The three NODES rows — two are free, one carries private state

| row | site | action | owner of the sheet | relocatable |
|---|---|---|---|---|
| Provider | `NodesView:386` | `onOpenRoutes()` | **RootView:406** (`routesSheet`) | ✅ pure raise |
| Gateway | `NodesView:399` | `onOpenGatewayEditor(resolution.config)` | **RootView:437** | ✅ pure raise, needs `resolution` |
| Route | `NodesView:377` | `routeSheet = true` | `NodesView:79` **private `@State`** + `:289` private `routeSelectSheet` (~35 lines over `routes`) | ⚠️ moves with its sheet |

`routes` is `@ObservedObject var routes: RouteCatalogStore` — **received, not
owned** (`:70-75`), already passed from `RootView:671`. So SETTINGS can take the
same store and the Route sheet travels intact. This is a *move*, not an
extraction: there is exactly one `routeSelectSheet`, and it ends up in exactly
one place.

📌 Incidental defect found while reading: rows at `:379`, `:388` and `:400` all
pass `last: true`. Three rows each claiming to be the last one — cosmetic
(divider suppression), real, and it disappears when the rows move.

## 3. 🔴 The hazard — shrinking a census subject

**Seven test files grep `NodesView.swift` by filename.** Arc B's lesson was that
a *pasted* view inherits no censuses. Arc D's inverse: a *shrunken* view leaves
its censuses measuring a view that no longer does the thing.

    CallSiteOrderTests:167   assertMonotone("NodesView", … minimumArity: 4)
    CallSiteOrderTests:210   testTheThreeSubjectsAreActuallyDistinct
                             home ≠ nodes ≠ editor label lists
    HonestControlsTests:180  slice of codeOnly(NodesView.swift) — ENROLL disable
    NodeRowSourceTests:26    NodeRow's own source
    RoutePickerCensusTests:7 "paste a second picker into NodesView.swift"
    CommissionStoreTests, RecallTests, G0EditorTests

Moving `onOpenRoutes` / `onOpenGatewayEditor` / `resolution` off `NodesView`
drops its arity below 4 — the floor reds on a correct tree, which that file's own
comment anticipates verbatim ("a floor left at 5 would go red on a correct
tree"). Lowering it is legitimate **only if the new view gains the same
instrument**: `SettingsView` must be added to the monotone walk *and* to the
3-way distinctness control, else the arity that left NodesView is guarded by
nothing anywhere. That is the Arc-B anchor-moved requirement, arriving from the
subtraction side.

`HonestControlsTests`' ENROLL slice stays put — ENROLL is not moving.

`NodeRow` itself is declared at `NodesView.swift:736`. A SETTINGS view using it
reads a component out of a sibling view's file. Either extract `NodeRow` with
the rows, or accept the cross-file use and say so at the leg. Lean: extract —
`NodeRowSourceTests` already treats it as a subject in its own right.

## 4. Narration — a third reader, and the one way to get it wrong

`NarrationPreference` (`Narrator.swift:34`) is a free enum over one key,
`zeus.narration.voiceOn`, default ON. `Narrator.voiceOn`'s `didSet` persists it
and stops the synthesizer on mute. The existing toggle is in **SessionView**
(`narrationOn` at `:199`, rendered `:691`), driven from `RootView:659-667`
against the single `replyNarrator`.

🔴 A SETTINGS toggle must write **that instance**, not a fresh `Narrator()`.
Two `Narrator`s over one key is drift by construction: mute in settings, and the
session's narrator keeps its stale `@Published false` until relaunch — the same
`@StateObject`-doesn't-re-init defect Arc B caught at the commission seam, in a
new costume. The leg is a form leg, not a count: **exactly one production
`Narrator(` instantiation**, both toggles resolving to it.

## 5. Open ruling for the coordinator

**Move or mirror.** My lean is move: two doors to one write is the duplication
hole Arc B just closed, and a SETTINGS tab that duplicates NODES rows earns the
same census-inheritance problem in reverse. The cost is that merakizzz sees NODES
lose three rows he first saw in 192. If that reads as a regression, the honest
alternative is a single NODES row that *raises to the settings tab* — one line,
no second write path.

## 6. Planned build-alive mutations

| mutation | expected red | why it is the honest shape |
|---|---|---|
| 4th tab added, `DeepLinkTests` floor left at 3 | `testEveryTabIsReachable` | proves the reachability loop, not the count |
| settings tab case rendered but not in `allCases`-driven bar | tab-reachable leg | compiles; a hand-rolled bar would hide it |
| `SettingsView` dropped from the distinctness control | distinctness leg | the anchor-moved proof, subtraction side |
| second `Narrator()` in settings (type kept) | one-owner form leg | compiles and *looks* correct — the drift shape |
| a relocated row's action closure emptied | relocated-control leg | dead control, the Arc-A defect class |

Aperture: source census at `929db99`, simulator only, no device run.
