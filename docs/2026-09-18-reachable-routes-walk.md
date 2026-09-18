# Arc B — the reachable ROUTES sheet (walk)

Base: `93d7394` on iOS `main`. Read-only. No code touched by this commit.

Subject: make a provider choosable AFTER commissioning, so the phone can run
a real turn. Census finding at `a315bbf` that motivates it:
`recordRoutesChoice` production callers = 2, and the second (`RootView:238`)
is unconditionally `nil` in release. `SET A PROVIDER` (`Commissioning:832`)
lives on a screen that is gone after `onComplete` (`:812`). `decommission()`
production callers = 0. So an operator who finishes onboarding without a
provider has no path to add one, ever.

---

## 1. What the spec said to reuse, and what is actually there

The dispatch said: reuse `routesCTAEnabled` / `ProviderCatalog.current.rows()`
/ `ModelPoll` / the key write. Three of those four are **not reachable from
outside `CommissioningView`**, and the fourth is reachable but is only half
the machinery.

| symbol | site | reachable from NODES? |
|---|---|---|
| `routesCTAEnabled` | `Commissioning:1108`, `static` on the view | ✅ yes — already extracted, already has 6 behavioural legs |
| `ProviderCatalog.current.rows()` | `ProviderCatalog:82`, a global | ✅ yes |
| `ModelPoll` | `ModelPoll.swift`, its own type | ✅ the *state machine* — but not the *driver* |
| the key write | `Commissioning:1071`, inline in the CTA closure | ❌ no — a closure inside a private computed var |

The driver is the gap. `schedulePoll(for:)` (`:1186`) and `startPoll(for:)`
(`:1207`) are **private methods on `CommissioningView`**, and they read six
pieces of private `@State`: `providerPick`, `keyText`, `modelText`,
`baseURLText`, `providerRows`, `modelPoll`, plus `pollTask`. `routesStep`
(`:880`) — search field, grouped list, model picker, key field, base-URL
field, CTA — is ~180 lines of private computed var over exactly that state.

So "put a ROUTES sheet in NODES" is not a wiring job. It is either a
**duplication** or an **extraction**, and those are not the same risk.

## 2. Why duplication is structurally unguarded here

29 test references grep `Sources/ZeusApp/Commissioning.swift` **by filename**.
Every census leg that guards the picker is anchored that way:

- `CommissionStoreTests:299` — the `"anthropic"` provider-literal ban, corpus
  = `Commissioning.swift`.
- `ModelPollTests:132` — "the free-text MODEL field is not gated on the
  catalog arriving" (the Ollama-only defect), corpus = `Commissioning.swift`.
- `ModelPollTests:166` — "key entry cancels the pending poll", same corpus.
- `CommissionStoreTests:262` — "the CTA calls the writer", same corpus.
- `PickSeamTests:88` — "the debug seam writes view state, not the record",
  same corpus.

A second picker pasted into `NodesView.swift` inherits **none** of them. It
could hardcode `"anthropic"`, gate the model field on `.listed`, open one HTTP
request per keystroke, and every one of those five legs stays green — because
their subject is a *file*, not a *behaviour*. That is Standards #5 exactly: a
file-scoped instrument read as if it were scope-free. It is also the third
arrival of correct-but-structurally-unreachable on this app.

**Ruling: extract, do not duplicate.** The picker becomes one type both
callers render. The existing legs keep their meaning if their corpus follows
the code — which means the census anchors move to the new file in the same
commit, not later.

## 3. Why the commit closure cannot live in `NodesView`

Writing a commission post-commissioning does **not** re-arm the core. The
chain is `AppState.commission(_:)` → `store.save` → `@Published` → `ZeusApp`
re-evaluates `if let commission`. But `RootView`'s `configSource` is a
`@StateObject`: re-evaluating the parent body does not re-run `RootView.init`,
and the `.task` at `RootView:442` has no `id:`, so it does not re-fire either.
The pill and the AGENT tile would keep rendering `NO PROVIDER` until relaunch.

The precedent that already solves this is the gateway editor
(`RootView:391-408`): its `onSaved` does the pure `resolve` first (whose
`.local` arm is `.checking` by construction, so the old reading cannot survive
the write) and then `Task { adopt(await armedResolution(...)) }`.

So the sheet follows `onOpenGatewayEditor`'s existing seam: **NODES raises,
RootView owns.** `NodesView` gets a call-up closure; `RootView` holds the flag,
renders the overlay, and owns the commit — because `armedResolution(store:
keys:)` needs `store` and `keys`, and `NodesView` has neither and should not.

## 4. `#if DEBUG` reachability

The arc's stated invariant is `recordRoutesChoice` production callers ≥ 2 with
one reachable outside `#if DEBUG`. Today's second caller (`RootView:238`) sits
inside `armedResolution` guarded on `LaunchArgs.seededProvider`, which is
`#else return nil` in release — live code, unreachable value. The sheet's
commit is the first unconditionally-reachable second caller. The leg must
assert **reachability**, not count: a count of 2 is already true and would
ship green today.

## 5. Shape

1. `ProviderPicker` — a `View` owning the six pieces of state, the poll
   driver, and the CTA, parameterised by `keys:` and a
   `onCommit: (providerID, model, baseURL) -> Void`. `CommissioningView`
   renders it as `routesStep`; the NODES sheet renders it too.
2. `NodesView` Route row → `onOpenRoutes()` call-up (mirrors
   `onOpenGatewayEditor`).
3. `RootView` owns `routesSheet`, renders the overlay, and on commit:
   `store.save(updated)` → `configSource.adopt(resolve)` →
   `Task { adopt(await armedResolution) }`.
4. Census anchors follow the code into the new file; the ban on provider
   literals and the not-gated-on-catalog leg must cover **both** corpora.

## 6. Aperture

Source census at `93d7394`, not a device run. Every "reachable" below is a
claim about call paths in this tree, not about a tapped build.
