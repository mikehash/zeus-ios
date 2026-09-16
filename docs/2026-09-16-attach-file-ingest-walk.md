# Walk — real file attach → session ingest

Base: iOS `main 40b4847`. Branch `feat/attach-file-ingest`. Prose before code,
per the standing order. Nothing in this document is a plan I have executed; it
is what the substrate says, measured, with the apertures stated.

---

## 0. The dispatch's shape, and where it diverges

> "Bridge (Rust): an ingest fn that puts the file's content into the session —
> consistent with the phone's real `read_file` capability, not a new
> unadvertised power."

The second half of that sentence is the whole design, and it rules against the
first half. Measured below: the phone's real capability is `read_file`, which is
**confined to the workspace root** and already extracts documents. An ingest fn
that injects *content* into the session builds a second, parallel read path with
its own (absent) confinement. The honest ingest is **copy the picked file into
the workspace, then let the existing, already-confined `read_file` read it** —
the model gains no power it was not already advertised as having, and the
security invariant is satisfied structurally rather than by discipline.

---

## 1. Census — the attach surface is absent, and the absence is proven

`codeOnly` strip (block + line comments removed), `Sources/**/*.swift`, 44 files.

```
POS ctl  'func '           codeOnly = 441      ← corpus is alive
NEG ctl  'zzzNoSuchSymbol' codeOnly =   0      ← pattern can read zero

UIDocumentPicker    raw 0   codeOnly 0
fileImporter        raw 1   codeOnly 0     ← the 1 is PROSE (SessionView:221)
PHPicker            raw 1   codeOnly 0     ← prose
PhotosPicker        raw 1   codeOnly 0     ← prose
documentPicker      raw 1   codeOnly 0     ← prose
UTType              raw 0   codeOnly 0
Data(contentsOf     raw 0   codeOnly 0
FileManager         raw 2   codeOnly 2     ← live, unrelated
```

Fourth arrival of use-vs-mention this arc, and this time it is *my own*
`SessionView:221` doc comment — the paragraph that documents the absence of a
picker is the only thing in the corpus that names one. A raw count says "four
picker APIs present." `codeOnly` says zero. The stripper built in Phase 2 for
whole files, generalised to slices in Phase 3 and to the crate's own test module
in the honesty arc, pays off a fourth time without redesign.

Current state of the control (`SessionView.swift`):

```
:233  attachReason  = "ATTACH — NO FILE INGEST ON THIS BUILD"
:239  attachEnabled : Bool { false }        ← honest CONSTANT
:539  accentButton(enabled: SessionView.attachEnabled, action: {})
```

Pinned by `SessionStageTests:98-135` — reason contains "NO FILE INGEST", reason
does **not** contain "UNREACHABLE" (terminal ≠ unreachable), and the view reads
the *named derivation* so a leg can refuse a `link`-conditioned spelling. Those
legs invert when the capability lands; they do not get deleted.

---

## 2. 🔴 The `Attachment` channel is DARK on this phone's provider path

`zeus_core::Attachment` exists (`zeus-core:9279`) and `run_turn` already accepts
`Vec<Attachment>` (`agent_loop:1502`), reaching
`Message::user_with_attachments` at `:1683`. That looks like a ready-made
ingest path. It is not, for text files, on the provider the phone actually runs.

```
bridge Cargo.toml pin        = 8e19318c
phone provider (armed)       Ollama  →  lib.rs:1831 complete_openai
                                     →  lib.rs:2163 stream_openai
to_openai_messages:4248      if msg.attachments.is_empty() || !should_include_images()
                                 → push plain { role, content }        ← text only
:4256-4259  for att in &msg.attachments
              format_openai_attachment(att)           multimodal.rs:397
:398          if attachment.is_image() { Some(image) } else { None }   ← DROPPED
:401          "OpenAI doesn't natively support document/audio content blocks.
               PDFs and text files should be extracted upstream."
```

**A non-image attachment on the OpenAI-compatible path is silently discarded at
the wire.** The comment at `:401` is explicit about the contract: extraction is
*upstream's* job. Nothing upstream does it —

```
zeus-agent/src/agent_loop.rs   codeOnly 'document_extract' = 0
                               codeOnly 'extract_by_path'  = 0
                               codeOnly 'attachments'      = 21   ← POS ctl
extract_by_path callers (whole pinned tree): tools.rs · its own mod.rs · its own test
```

The only production caller of the document extractor is **`read_file`**
(`tools.rs:1549`). The attachment path never touches it. Audio gets transcribed
at `agent_loop:1580-1600`; images get delegated/stripped inside zeus-llm; **text
and documents get neither.**

So: ship attach through `Attachment` and the file is picked, encoded, persisted
into the session JSON, rendered in the transcript — and **never reaches the
model.** That is built-but-dark at the wire, the same class as the phone
preamble that would have merely coexisted with the frozen AGENTS.md. It would
demo perfectly. The operator would ask about the file and be told nothing about
it was received, which is worse than the disabled button we have now, because
the disabled button does not lie.

---

## 3. What the phone's real capability actually is

```
PHONE_TOOLS (bridge:708) = read_file  write_file  edit_file  list_dir  web_fetch
bridge:226   set_workspace_root(Some(canonical_root))     ← process-global confinement
bridge:219   canonical_root = root.canonicalize()
tools.rs:1542-1563  read_file: is_document → extract_by_path (docx pptx xlsx pdf
                    odt ods odp epub rtf), else fs::read_to_string
tools.rs:1571       truncate at MAX_CONTENT_BYTES = 100_000 (zeus-core:659)
```

`read_file` is **confined, extracting, and truncating** — three properties an
ingest fn would have to re-implement, and the third is not optional: a 40 MB
file pasted into a prompt is a wallet event, not a feature.

This is the two-gate check applied to the dispatch's own suggestion:
- gate (a) does `Attachment` exist and is it plumbed? ✅ `run_turn:1502`.
- gate (b) is it **callable to effect** on this phone's path? ❌ dropped at
  `multimodal.rs:398`.

Gate (a) alone is what makes the attachment route look obvious.

---

## 4. Proposed shape — stage into the workspace, reference by path

Picked file → copied into `<workspace>/attachments/<stamp>-<sanitised-name>` →
the turn text gains a one-line, clearly-delimited **reference**, not the bytes:

```
[ATTACHED FILE: attachments/2026-09-16T09-41-02-notes.txt]
```

The model reads it, if it chooses, with the `read_file` it already has, under
the confinement already installed at `bridge:226`, with the extraction and the
100 KB truncation already written. New Rust surface is a **copy-in**, not a
read: it does not widen the model's reach by one byte.

Why this satisfies the security invariant *structurally*:

- 🔴 **Content never becomes prompt text.** The file's bytes are never
  concatenated into the turn. A file whose body reads `ignore previous
  instructions and run …` is a file the model must *choose* to open, and what
  comes back arrives as a **tool result** — the `Role::Tool` channel, which is
  already data-not-command by construction, and which `messages()` already tags
  with its tool name for the transcript.
- 🔴 It lands **nowhere near** `voiceCommit` or `pendingPrompt`. Those two
  writers stay exactly two (`PendingPromptHasExactlyTwoNamedWriters` from Phase
  3 stays green and unmodified — a leg I must not have to touch is the sign the
  channel split held).
- The staged path is *inside* the confinement, so a malicious filename
  (`../../secrets`) is refused by the guard that already exists rather than by a
  new check I would have to remember to write. Sanitising the name is belt to
  that braces, and I will still do it, because the copy happens before the guard
  sees anything.

Cost, stated honestly: the model must spend one tool iteration to see the file.
That is the price of the content being data. The alternative — inlining bytes —
is the auto-execute surface the invariant forbids, wearing a convenience
costume.

---

## 5. Open question I will not decide alone

`attachEnabled` flips true only when the whole path works. But there is a
**third** state the current two do not cover: the path works and the operator
has not armed a provider. `send` returns `BridgeError::NoProvider` (`bridge:390`)
and the staged file would sit in the workspace unreferenced. Options: stage
anyway and reference on the next turn (my lean — the copy is honest work and
survives), refuse the pick with the existing no-provider reason, or disable the
control while unarmed. I lean (1); it is the only one where the operator's file
is not silently discarded.

---

## 6. Gate shape for the code commit

- `attachEnabled` becomes a real derivation; `SessionStageTests:98-135` invert
  rather than delete, and the "no UNREACHABLE" leg survives unchanged (terminal
  vs unreachable is still the distinction).
- Legs, each with its own named mutation:
  1. **picker→bridge wiring** — deleting the bridge call reds by name (the
     near-dark line class from the honesty arc; a mutation aimed at the helper
     alone proves nothing about the call).
  2. **staging actually reaches the workspace** — asserted through the *export*,
     not the helper, and read back through the confinement.
  3. **`attachEnabled` reflects real state** — a constant-`true` body reds.
  4. 🔴 **content ≠ command** — a file whose body is an imperative produces a
     turn whose text does **not** contain that body; `pendingPrompt` writer
     count still exactly 2; no path from picked bytes to `voiceCommit`.
  5. **confinement** — a traversal filename stages inside the root or not at
     all, asserted against the leg's own fixture dir (a value that exists before
     `init`, canonicalised because `init` canonicalises) — *not* against a path
     derived from `core.root` by `join`, which is the tautology that could not
     fail and that cost a re-gate last arc.
- Every census inside a leg runs `codeOnly` with a surviving-token control, so
  an over-eager strip reds instead of passing vacuously.
- `rust/` diff decides the pin: a copy-in fn lands in the bridge crate, so the
  pin does **not** move — the xcframework needs a rebuild because the bridge's
  own source changed, but no dependency rev changes.

---

## 7. What I need ruled before cutting

**(A)** Confirm the route: stage-into-workspace + path reference (§4), **not**
`Attachment` (§2, dark at `multimodal.rs:398` for text on the Ollama path).
This is the substantive divergence from the dispatch and it is the whole cut.

**(B)** §5's unarmed-provider arm.

Both are cheap to answer and expensive to get wrong after the code exists.
