# S5 — memory over REST: the pre-cut walk

Base: `80a3489a3ef45b82522be1f6ecde952462b9dcf9` (iOS main), tree `e7791a45`, porcelain 0.
Author: zeus106. Ruled by Zeus100 across A / B / B′ / B″ / C / C′ / C″.

> **Why this file exists twice over.** I claimed in-channel that this walk was
> written to disk. It was not — `ls docs/` at `80a3489` showed eight files and
> `git log --all --diff-filter=A -- 'docs/*S5*'` returned zero lines, so it was
> not on any ref either. A phantom artifact: an artifact reported landed that
> was never written. The map existed only in channel scrollback, which does not
> survive a context death. Landed ≠ live, and *claimed written* is one rung
> below landed.

## 0. The base is verified, the old branch is wreckage

- `main = 80a3489`, tree `e7791a45` — byte-identical to my `404d51b`, so the
  rebase-to-land preserved content exactly.
- `feat/remote-gateway-parity @ 0994ead` is a **sibling**, not an ancestor
  (`merge-base --is-ancestor 404d51b 80a3489` → rc=1). S5 branches from `main`.

## 1. The four fabrication sites on one `NodeRow` call

`NodesView.swift`, the search-hit row. Three of four slots are file-shaped;
exactly one field is genuinely shared across both wire arms.

| slot | today | why it is a fabrication for a memory hit |
|---|---|---|
| `icon` | `"doc"` — hardcoded literal | the glyph asserts "file" before a string is read |
| `label` | `pair.element.name` | `SearchHit.name` is file-arm only; mnemosyne has `memory_type` |
| `onToast` | `Recall.dirLabel(path) ?? "… WORKSPACE ROOT"` | path + the root sentence are file facts |
| `value` | `Recall.scoreLabel(score)` | **survives** — score is on both arms, kind-agnostic |

`Recall.dirLabel` (`Recall.swift:181`) documents its own conflation in its doc
comment: *"or `nil` at the root."* That `nil` means **at the root** (a file
fact). It must never also mean **has no path** (a memory fact).

**Ruling:** the site switches on `kind`. The memory arm is then *structurally
incapable* of reaching the icon literal, the name slot, or `dirLabel` — a
branch witnessed, which is stronger than a NEG asserting absence.

## 2. `findSummary` is FILES-denominated end to end

`Recall.findSummary` past the `NO CORE` arm:

- `:161` `N FILES INDEXED`
- `:164` `INDEX EMPTY — NOTHING TO SEARCH`
- `:165` `NO MATCH IN N FILES`
- `:166` `N OF M FILES`

Doubly file-scoped, because remotely `indexSize` is `GET /v1/memory/files`.
A mixed result set separates the counts: the FILES vocabulary describes the
file portion only, memory hits carry their own. `NO CORE` / `READING` above are
locality and liveness — untouched.

## 3. The two wire shapes of `POST /v1/memory/search`

```
mnemosyne arm  {id, session_id, content, score, memory_type, importance}   NO path
file arm       {path, snippet, score}          + "search_method": "hybrid"|"file"
```

`SearchHit.path` is `public var path: String` — **generated, non-optional**
(`zeus_core_bridge.swift:1219`). `path: Optional` is unwritable without moving
the pin, the same gate-(b) wall as `SessionInfo.updatedAtRfc3339` at `2473e3b`.

**Seam type, precedent `SessionRow`:** app-owned `RecallHit` with a `kind`
discriminant — `.file(path, snippet)` / `.memory(id, type, content)`. Embedded
conformer maps FFI `SearchHit` → `.file`; the gateway decoder branches on the
**structured fields** (`path` → file, `id`/`content` → memory) with
`search_method` as corroborating metadata, never the decision. `rust/`
untouched, pin unmoved.

## 4. `search` / `indexSize` → `async throws`

`SessionCapabilities:129-130` already mandates the throw in prose — *"a
conformer that cannot run the query at all must THROW — an empty array is
'asked and got nothing', which is a lie if nobody asked"* — over a
non-throwing `-> [SearchHit]` at `:132`, while `GatewayCapabilities:122`
returns exactly the `[]` the comment forbids (and `:115` returns `nil` for
`indexSize`). Unreachable today because the census guard holds
`NodesView(core:)` on embedded. **S5 migrates that site, so S5 is where the lie
goes live** — the throw lands in this commit.

The S3b machinery is already waiting: `readIndexSize()` is **already `async`**,
and `runFind` already calls `Recall.mayWriteResult(generation:current:)` before
`findHits = hits`. The conversion inherits the staleness legs.

## 5. The fifth write-outcome string

`Recall.rememberToast(.written)` reads `MEMORY WRITTEN · THIS DEVICE`;
`.noCore` reads `NO CORE ON THIS DEVICE — NOTHING TO WRITE TO`. Both are
**locality claims about the embedded path**. On a `.resolved` config the remote
*has* a core. The outcome string is selected by the config **arm** — which
resolution already knows, and `configSource.config` is already in scope in
`RootView` — never by a nil-core probe.

## 6. The census cue drifted, latently

```
guard prints:  RootView:224 · :499 · :545 · Commissioning:1222
actual:               :222 · :546 · :592 ·             :1222
```

3 of 4 stale, caused by S3b's own edits pushing `RootView` down. The cue prints
**only when the guard reds**, which is S5 — so no gate between S3a′ and now
could have caught it. The repair is to name the enclosing **symbol**
(`armedResolution(store:keys:)`, the NodesView search/indexSize call site,
`remember(_:)`, Commissioning's `listModels`), and to have the **same leg that
prints a symbol assert it** (filter count > 0).

> **Rule banked:** an emitted coordinate the instrument cannot re-derive at run
> time is a comment wearing an assertion's clothes. The self-assert makes the
> coordinate load-bearing on *every* run, not only on the run where it is read.

## 7. The cut, in order

1. `RecallHit` seam type + `kind`; embedded conformer maps FFI → `.file`.
2. `search` / `indexSize` → `async throws` on the protocol; both conformers.
3. `GatewayCapabilities`: `POST /v1/memory/search` two-arm decoder,
   `POST /v1/memory/remember`, `GET /v1/memory/files`; **throws**, never `[]`/nil.
4. Render: per-`kind` construction of the whole `NodeRow`.
5. `findSummary`: split denominators, FILES count names its aperture.
6. Census cue → symbols, self-asserted; migrate `NodesView(core:)` +
   `remember(_:)`, leaving the count pinned by its **set**.

## 8. The mutations that must red before this is done

| mutation | expected |
|---|---|
| gateway `search` throws → returns `[]` | the "cannot run ≠ no hits" leg reds |
| decoder maps only the file arm | the both-arms-consumed leg reds (memory hits silently dropped) |
| render drops the `kind` switch, hardcodes `icon: "doc"` | the memory-arm branch leg reds |
| `.resolved` outcome string → the local no-core string | the locality NEG reds |

Each must red **with the build alive** (count still executes), and each anchor
asserted unique — a slice that finds nothing must report VOID, not pass.
