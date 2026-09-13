# Remote-gateway parity on the device — design

**Branch:** `feat/remote-gateway-parity`, from iOS main `f2511a3f`.
**Gateway substrate:** `~/Zeus` @ `2158379a`. Every endpoint below was checked against
`.route(` **registrations** in `crates/zeus-api/src/routes.rs`, not against `docs.rs` — that
file is a documentation table and lists routes the router does not serve.

---

## 0. The dispatch's premise is already half-built, and that changes the plan

The order reads "`EmbeddedTransport` today → a `GatewayTransport` over `/v1/ws` + REST".
Measured on the tree at `f2511a3f`:

```
POS  grep -rn "HTTPTransport(" --include='*.swift' .
       Session.swift:174   ← PRODUCTION call site, inside makeTransport
       HTTPTransportTests.swift:232,243
NEG  "ZzzNoSuchTransport("  = 0        POS ctl "EmbeddedTransport(" = 3 files
```

**A remote transport already exists, is already the second conformer to `SessionTransport`,
and is already reachable in production.** `makeTransport(for:sessionID:credentials:)` routes
`.resolved(endpoint)` to `HTTPTransport` and `.local` to `EmbeddedTransport`. `GatewayConfig`
already has `.absent / .local / .malformed / .resolved`, `GatewayTokenStore` already holds a
Keychain-backed token, `GatewayEditor` already has a preflight.

⚠️ **So "add a `GatewayTransport`" as worded would create a third conformer alongside a
working second one.** I am not cutting that. The honest statement of the work is:
**the remote path exists for PROSE only, and every other feature on the device is
embedded-only.** The parity gap is not the transport — it is the six surfaces that take a
`ZeusCoreProtocol` directly and therefore cannot be served by a gateway at all.

*(Note on my own probe: the first census I ran used an unquoted `--include=*.swift` under zsh,
which died with `no matches found` and printed nothing. An empty result there is
indistinguishable from "no call sites" — which would have had me deleting a live transport.
Quoted, with a negative control, on the re-run.)*

---

## 1. The seam, as it stands and as it should stand

```
SessionEngine
  └─ makeTransport(for:sessionID:credentials:) → SessionTransport   ← THE SEAM
       .local(_)        → EmbeddedTransport(core:)   in-process Rust
       .resolved(ep)    → HTTPTransport(endpoint:)   POST /v1/chat
       .absent          → UnconfiguredTransport      fails loudly
       .malformed(_)    → MisconfiguredTransport     fails, quoting the operand
```

`SessionTransport` is one method: `stream(prompt:) -> AsyncThrowingStream<SessionFrame, Error>`.
That is the correct seam and it does not move. **The defect is that it is the ONLY seam.**

Six surfaces bypass it and hold a core directly:

```
grep -rn "core: ZeusCoreProtocol" --include='*.swift' Sources/ZeusApp/
  ProviderArming.swift:40,110,167     NodesView.swift:125
  HistoryView.swift:24                EmbeddedTransport.swift:72,86
```

Each of those is a feature that **silently degrades or dies** when the operator is on a remote
gateway, because `core` is `nil` or is a local core that knows nothing about the remote node.
That is the parity gap, and it is what the step list attacks.

**Proposal: a second protocol, not a second transport.** `SessionCapabilities` — the
non-prose surface (sessions, replay, memory search, models) — with two conformers,
`EmbeddedCapabilities` (wraps `ZeusCoreProtocol`) and `GatewayCapabilities` (REST). The views
take `SessionCapabilities?` instead of `ZeusCoreProtocol?`. One seam per *kind* of traffic,
resolved from the same `GatewayConfig` that already resolves the transport.

---

## 2. `/v1/ws` — measured, and NOT what step 2 should use

```
routes.rs:1094   .route("/v1/ws", get(websocket::ws_handler))     registrations=1
routes.rs:176    .route("/v1/models", get(handlers::openai_list_models))
routes.rs:528    .route("/v1/sessions/:id/replay", get(handlers::session_replay))
"/v1/chat/completions"  registrations=0      ← named in docs.rs, NOT ROUTED
NEG "/v1/ZZZNOSUCH"     registrations=0
```

`/v1/ws` is real. But `SSEDecoder.swift` — 363 lines, three measured axum tolerances,
already written — has **zero production consumers** (`grep -rn SSEDecoder Sources/` outside
its own file = 0). We have a dark decoder for a streaming route that `routes.rs` does not
register (`/v1/chat/completions` = 0 registrations).

📌 **Ruling I want from you:** streaming is a *separate* cut from parity, and `/v1/ws` is a
node-control socket, not a chat stream. Parity should ride the REST routes that exist and are
already used by `HTTPTransport`. Wiring the dark `SSEDecoder` is worth its own commit later,
against whichever route actually streams — and that needs a gateway-side answer first.

---

## 3. Base URL and token — already resolved, stated for completeness

Nothing new is needed here, and re-deciding it would duplicate state:

- **Base URL:** `GatewayConfig.Source` is already `{ environment, commission, unset }` —
  precedence is env var, then the commissioning step, then absent. `GatewayEditor` validates
  (`notAURL / missingScheme / unsupportedScheme / missingHost`) so a bad URL renders as a
  *quoted refusal*, not a dead gateway.
- **Token:** `GatewayTokenStore` (Keychain, `GatewayTokenStoring: AnyObject`) already exists
  and `HTTPTransport` already takes `credentials: CredentialProviding`.

✅ **Verified rather than assumed.** I first wrote this section saying only that the dependency
was *injected*, flagging that "the token is injected" and "the token is sent" are different
claims. Then I measured the second one:

```
HTTPTransport.swift:143   if let token = credentials.credential(for: endpoint) {
HTTPTransport.swift:144       request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
```

The header is attached, conditionally on a credential existing for that endpoint. So the
remote prose path is genuinely authenticated today. Recording the sequence because the
hedge was one grep away from being an answer — a flagged assumption I could have resolved
in ten seconds is a flagged assumption I should have resolved before writing it down.

---

## 4. Sessions and replay — the mapping, and where it breaks

| Embedded | Remote | State |
|---|---|---|
| `core.sessions()` | `GET /v1/sessions` (registrations=2) | mappable |
| `core.messages(id)` | `GET /v1/sessions/:id/replay` (=1) | mappable, **shape unverified** |
| `core.remember(text)` | — | **no endpoint** |
| `core.search(query)` | `POST /v1/memory/search` (=1) | mappable, shape unverified |
| `core.indexSize()` | — | **no endpoint** |

📌 The `tool_name` join I cut at `4244aea` lives in the **bridge**, so replay over REST
re-opens that question: whether `/v1/sessions/:id/replay` carries tool names at all, or
whether the remote path regresses to `[TOOL]`. Unmeasured; it is step 3's first act.

---

## 5. The picker against a remote gateway — the finding that matters

```
chat_handlers.rs:1292  pub async fn openai_list_models(State(state)) -> Json<Value>
  → { "object": "list", "data": [ { "id": state.config.model, "owned_by": "zeus" } ] }
```

🔴 **`/v1/models` returns exactly ONE model — the gateway's own configured model.** It is not
a provider catalogue. The picker's whole shape at `f2511a3f` (poll on key paste, list, degrade
to free text) assumes a catalogue keyed by an API key the *phone* holds. On a remote gateway
the phone holds no provider key at all — the gateway does.

So the honest behaviour is **not** "poll `/v1/models` and show the list". It is: on
`.resolved`, the provider/key rows are **not the operator's to set**, and the MODEL field
should render the gateway's single configured model as **read-only provenance** —
`MODEL: <id> · SET BY GATEWAY` — with the key field absent, not empty.

⚠️ **The failure this prevents:** showing an editable picker with one entry makes the operator
believe they chose a model, when the gateway will use its own regardless. That renders as a
working feature. Same class as the `Ok(vec![])` fold — "one model" and "the only model I am
allowed to report" must not look alike.

---

## 6. Failure states on screen

Three, and they must stay distinguishable — the picker taught us what happens when two
collapse into one:

| State | Trigger | Renders |
|---|---|---|
| unreachable | transport error, DNS, timeout | `GATEWAY UNREACHABLE — <host>` |
| unauthorized | 401/403 | `REFUSED BY GATEWAY: <its own sentence>` |
| version mismatch | see below | `GATEWAY TOO OLD — needs <route>` |

🔴 **Version mismatch has no instrument yet.** There is no version handshake — I checked for a
route and found none registered. A 404 on a route we expect is the only available signal, and
"this gateway is old" is indistinguishable from "this gateway is misconfigured" from a 404
alone. **I would rather render `ENDPOINT MISSING: <path>` — which is literally what we
observed — than claim a version inference the wire does not support.** Flagging for your ruling;
a real fix is a gateway-side `/v1/version`, which is a Zeus cut, not a phone cut.

---

## 7. Gap list — embedded features the remote path cannot do, with the endpoint needed

| # | Feature | Site | Remote status | Endpoint needed |
|---|---|---|---|---|
| G1 | Prose turn | `SessionView` | ✅ **works** — `POST /v1/chat` | — |
| G2 | Session list | `HistoryView:181` | ❌ core-only | `GET /v1/sessions` (exists) |
| G3 | Replay transcript | `HistoryView:194` | ❌ core-only | `GET /v1/sessions/:id/replay` (exists) |
| G4 | Replay **tool names** | `History.swift` | ⚠️ unknown | depends on replay payload shape |
| G5 | REMEMBER | SESSION composer | ❌ core-only | **none — needs a write endpoint** |
| G6 | MEMORY SEARCH | `NodesView:475` | ❌ core-only | `POST /v1/memory/search` (exists) |
| G7 | Index size vacuity probe | `NodesView` | ❌ core-only | **none** |
| G8 | Provider arming / key entry | `ProviderArming:40` | ❌ n/a by design | gateway owns its keys |
| G9 | Model list | `ProviderArming:174` | ⚠️ degenerate | `/v1/models` returns 1 (§5) |
| G10 | Tool-call loop + sandbox | bridge | ❌ core-only | gateway runs its own; unobservable from phone |
| G11 | Streaming deltas | `SSEDecoder` (dark) | ❌ | no streaming chat route registered |

**Two items have no endpoint at all (G5, G7) and one is degenerate (G9).** Full parity is
therefore not reachable from the phone alone; it needs three Zeus-side routes. That is the
single most important sentence in this doc and I would rather say it now than discover it at
step 4.

---

## 8. Proposed step list — one commit each, each gated

| Step | Content | Bridge touched |
|---|---|---|
| **S1** | This doc. | no |
| **S2** | `SessionCapabilities` protocol + `EmbeddedCapabilities` wrapping `ZeusCoreProtocol`. Views take the protocol. **Pure refactor, zero behaviour change** — the leg is that all 544 still pass. | no |
| **S3** | `GatewayCapabilities`: sessions + replay over REST. Legs incl. a fixture for the replay payload, and G4 answered. | no |
| **S4** | Capability resolution from `GatewayConfig`, wired to `HistoryView` / `NodesView`. MUT: resolve always-embedded → remote legs red. | no |
| **S5** | Memory search over `POST /v1/memory/search`; **G5/G7 render as an explicit `NOT AVAILABLE ON A REMOTE GATEWAY` state, not as empty results.** | no |
| **S6** | §5 picker: read-only gateway model provenance; §6 failure states. | no |

`git diff --stat -- rust/` is **empty for every step**. No bridge change is needed for parity —
the gap is Swift-side wiring plus three missing gateway routes.

---

## 9. What this doc does NOT establish

- **No leg has ever opened a socket to a real gateway.** Same sentence as build 161 and 166.
  Every step above is shape.
- The replay payload shape (G4) is an **unverified read**, named as such. (§3's header was
  flagged as unverified, then measured — it is confirmed.)
- Version mismatch (§6) is **unimplementable as specified** on today's wire.

**Awaiting your ruling on three things:** (a) second protocol rather than third transport,
(b) `/v1/ws` and the dark `SSEDecoder` deferred to a streaming cut, (c) `ENDPOINT MISSING`
instead of a version inference the wire cannot support.
