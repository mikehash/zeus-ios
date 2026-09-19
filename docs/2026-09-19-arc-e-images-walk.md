# Arc E walk — images on the phone

Read-only substrate walk at iOS `main = 2af7865`, bridge pin
`8e19318ccda7023a5c2ec59e4978c6a0855b8c50`. No code changed. Three questions
were asked before a line: which providers do vision and how a model is known
to be vision-capable; what shape the content part takes; what the picker path
costs. The answers move one of the two cuts.

---

## 1. The vision stack already exists, end to end, below the bridge

The pinned core is not missing vision. It is missing a *caller*.

    zeus-core:9279       pub struct Attachment { mime_type, data: Vec<u8>,
                                                 filename, source_url }
    zeus-agent:1193      pub async fn run_with_attachments(&mut self, &str,
                                                 Vec<zeus_core::Attachment>)
    zeus-agent:1499      async fn run_turn(&mut self, &str, Vec<Attachment>, …)
    zeus-llm/multimodal  Anthropic  → {"type":"image","source":{"type":"base64",…}}
    zeus-llm/multimodal  OpenAI-ish → {"type":"image_url","image_url":{url:data:…}}
    zeus-llm:4100        sanitize_images_for_vision_with_delegate(...)
    capabilities:548     pub fn supports_image_input(&Provider, &str)
                           -> Result<bool, String>

So the encoding question (2) has an answer that is not "build it": **the
content part is already built, per provider, in `zeus-llm::multimodal`, and it
is selected by provider rather than by the caller.** The caller's job is to
hand over `Vec<Attachment>` with `mime_type` and raw `data`. Nothing above
`zeus-llm` should be choosing base64 vs URL vs `image_url` — that is a
provider dialect, and the dialect table is already written.

## 2. The load-bearing gap is ONE bridge line, and it is a shape mismatch

    bridge:432   agent.run_structured(&text)          ← what send() calls
    agent:1222   run_structured(&mut self, &str) -> Result<TurnResult>
    agent:1223     self.run_turn(user_input, vec![], None)
                                         ^^^^^^
                                         attachments, hardcoded empty

`run_with_attachments` takes attachments but returns `String`. `run_structured`
returns `TurnResult` but hardcodes `vec![]`. **There is no variant at the pin
that is both structured and attachment-carrying** — and `send` needs
`TurnResult`, because the bridge reads `result.content` at `:447` and prefers
it over the streamed join.

Three options, and the sequencing ruling turns on which one is taken:

- **(a)** Call `run_with_attachments` and lose `TurnResult`. Rejected: it
  regresses the authoritative-body preference that `:447` exists to provide.
- **(b)** Re-pin forward to a sha where `run_structured` takes attachments.
  Costs an xcframework rebuild and drags in every unrelated change between
  `8e19318` and the new sha. Not obviously available — needs a census upstream.
- **(c)** Keep the pin and have the bridge build the attachment vec itself,
  passing it through a path that reaches `run_turn` with both. At this pin
  that means the bridge cannot use `run_structured` as-is.

**This is the load-bearing cut, and it is upstream of the picker.** No amount
of PhotosPicker work reaches a model until this resolves. I need a ruling on
(b) vs (c) before cutting, because (b) moves the pin and that is your call.

## 3. `stage_attachment` is the wrong shape for an image, confirmed

    bridge:676   stage_attachment(file_name, bytes) -> String   // "attachments/…"
    bridge:969   attachment_reference(rel_path) -> "[ATTACHED FILE: …]"
    bridge:330   "\(typed)\n\(attachmentReference(relPath: staged))"

The path goes into the *turn text*. The model then has to `read_file` it — a
text tool, on a binary. The content index already knows this: there is a leg
at bridge:1621 named `binary_files_are_named_but_not_content_indexed`. So the
existing attach path is correct for text and structurally incapable for images,
which matches the Arc-D prediction. An image must travel as `Attachment.data`,
never as a workspace path — different channel, not a better filename.

Note this does **not** make `stage_attachment` wrong. It stays correct for the
text case. The image path is an addition beside it, not a replacement.

## 4. The model gate is real, model-level, and already fails safe

`capabilities::supports_image_input` is a three-tier answer:

- provider-level `supports_vision: false` → `Ok(false)` (Ollama is `true`,
  "model-dependent", capabilities:149)
- catalogued model with `supports_vision: false` → `Err(reason)` — a *sentence*,
  not a bool
- GLM-family prefix → `Err(reason)`
- otherwise → `Ok(true)`

And when the gate says no, `sanitize_images_for_vision_with_delegate`
(zeus-llm:4100) **strips the images and injects an in-band note telling the
model to say it cannot see** — it does not silently drop them and it does not
let the model hallucinate a description. That is the honesty behaviour this app
already believes in, implemented below us.

🔴 **Consequence for the UI:** the phone must NOT invent its own vision
predicate. A Swift-side allow-list of model names is a second source for a fact
the core already owns, and it will drift the day a provider ships a new vision
model. The honest surface is either (i) export the core's gate over the bridge
and render its `Err` string, or (ii) let the attach succeed and let the decline
note arrive in the reply. (i) is better UX and one more export; (ii) is free
and never lies. I lean (i) *because* the `Err` arm carries an operator-readable
reason — rendering it is strictly more honest than a generic "not supported".

## 5. The picker is a genuine add, and it is the cheap half

    PhotosPicker | PHPickerViewController | UIImagePickerController
      | import PhotosUI                      → 0 hits in Sources/     (NEG)
    fileImporter                             → 3 hits, live           (POS ctl)
    project.yml UsageDescription keys        → 4 (mic, speech, …)
    NSPhotoLibraryUsageDescription           → absent

The absent plist key is **consistent with** there being no photo path, not the
cause of a dead one — there is nothing in the binary that could have been
denied. `PhotosPicker` (SwiftUI, iOS 16+) needs **no** usage description at all:
it runs out of process and returns only what the operator picked. So the plist
key should stay absent, and a leg should assert that it stays absent — adding
it would request a permission we never exercise.

merakizzz's "nothing happens" on #2 is therefore: he tapped attach, got the
*file* importer, and either found no images in Files or picked one and got a
path the model couldn't read. Both are the same root cause.

## Proposed sequencing

- **E1 (load-bearing, blocked on your ruling)** — the attachment channel:
  bridge `send` carrying `Vec<Attachment>` to `run_turn`, mime from the picker,
  no path in the turn text for the image case. Pin decision (b) vs (c) first.
- **E2 (cheap, independent)** — `PhotosPicker` on the SESSION composer,
  producing `(mime, Data)`, plus a leg pinning `NSPhotoLibraryUsageDescription`
  **absent** with its reason.
- **E3 (optional, honesty)** — export the core's `supports_image_input` and
  render its refusal sentence rather than a generic one.

E2 can be built and gated without E1 only if it is terminal-disabled until the
channel exists — otherwise it is a live-looking control that drops bytes, which
is the exact defect class Arc A retired. I would rather cut E1 first and have
E2 land into a channel that works.

## Aperture

Source census at iOS `2af7865` and core `8e19318`, on this box. Not a device
run, not a network call to any provider. Every "0 hits" above carries a POS
control in the same invocation. The claim "no structured+attachments variant at
the pin" is a grep of `crates/zeus-agent/src/agent_loop.rs` for
`run_structured` — 1 hit, its definition, quoted in full above.
